-- Public business applications are isolated from business ownership until an
-- active platform administrator reviews them. The applicant never supplies a
-- user ID or role. Approval matches a confirmed Auth account by email and uses
-- the existing authorized business provisioning workflow.

create table public.business_applications (
  id uuid primary key default gen_random_uuid(),
  business_name text not null check (char_length(btrim(business_name)) between 1 and 120),
  owner_full_name text not null check (char_length(btrim(owner_full_name)) between 1 and 120),
  business_email text not null check (char_length(btrim(business_email)) between 3 and 254),
  contact_phone text not null check (char_length(btrim(contact_phone)) between 7 and 32),
  category text not null check (char_length(btrim(category)) between 1 and 80),
  description text check (description is null or char_length(description) <= 500),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  submitted_at timestamptz not null default pg_catalog.now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id) on delete set null,
  business_id uuid references public.businesses(id) on delete set null,
  constraint business_applications_review_state_check check (
    (status = 'pending' and reviewed_at is null and reviewed_by is null and business_id is null)
    or (status = 'approved' and reviewed_at is not null and reviewed_by is not null and business_id is not null)
    or (status = 'rejected' and reviewed_at is not null and reviewed_by is not null and business_id is null)
  )
);

create index business_applications_status_submitted_idx
  on public.business_applications (status, submitted_at desc);
create unique index business_applications_one_pending_email_idx
  on public.business_applications (pg_catalog.lower(business_email)) where status = 'pending';

alter table public.business_applications enable row level security;
revoke all on table public.business_applications from public, anon, authenticated;
grant select on table public.business_applications to authenticated;

create policy business_applications_admin_read on public.business_applications
  for select to authenticated using (loyalloop_private.is_platform_admin());

create function public.submit_business_application(
  p_business_name text,
  p_owner_full_name text,
  p_business_email text,
  p_contact_phone text,
  p_category text,
  p_description text default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
set row_security = off
as $$
declare
  application_id uuid;
  normalized_email text := pg_catalog.lower(pg_catalog.btrim(p_business_email));
  phone_digits text := pg_catalog.regexp_replace(coalesce(p_contact_phone, ''), '[^0-9]', '', 'g');
begin
  if pg_catalog.char_length(pg_catalog.btrim(coalesce(p_business_name, ''))) not between 1 and 120
     or pg_catalog.char_length(pg_catalog.btrim(coalesce(p_owner_full_name, ''))) not between 1 and 120
     or pg_catalog.char_length(normalized_email) not between 3 and 254
     or normalized_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
     or pg_catalog.char_length(pg_catalog.btrim(coalesce(p_category, ''))) not between 1 and 80
     or pg_catalog.char_length(coalesce(p_description, '')) > 500
     or pg_catalog.char_length(phone_digits) not between 7 and 15 then
    raise exception 'Please review the required application fields.' using errcode = '22023';
  end if;

  -- A server-side cooldown prevents repeat submissions for the same contact
  -- address. The unique pending index also closes concurrent duplicate races.
  if exists (
    select 1 from public.business_applications ba
    where pg_catalog.lower(ba.business_email) = normalized_email
      and ba.submitted_at > pg_catalog.now() - interval '24 hours'
  ) then
    raise exception 'An application using this business email was submitted recently.' using errcode = '23505';
  end if;

  insert into public.business_applications (
    business_name, owner_full_name, business_email, contact_phone, category, description
  ) values (
    pg_catalog.btrim(p_business_name), pg_catalog.btrim(p_owner_full_name), normalized_email,
    pg_catalog.btrim(p_contact_phone), pg_catalog.btrim(p_category),
    nullif(pg_catalog.btrim(p_description), '')
  ) returning id into application_id;

  insert into public.audit_logs (actor_user_id, action, target_type, target_id, metadata)
  values (auth.uid(), 'business_application.submitted', 'business_application', application_id::text,
          pg_catalog.jsonb_build_object('status', 'pending'));
  return application_id;
end;
$$;

create function public.review_business_application(p_application_id uuid, p_decision text)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
set row_security = off
as $$
declare
  application_row public.business_applications%rowtype;
  matched_owner_id uuid;
  new_business_id uuid;
  base_slug text;
  candidate_slug text;
  suffix integer := 1;
begin
  if auth.uid() is null or not loyalloop_private.is_platform_admin() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if p_decision is null or p_decision not in ('approved', 'rejected') then
    raise exception 'Decision must be approved or rejected.' using errcode = '22023';
  end if;

  select * into application_row
  from public.business_applications ba
  where ba.id = p_application_id
  for update;
  if not found then raise exception 'Application not found.' using errcode = 'P0002'; end if;
  if application_row.status <> 'pending' then
    raise exception 'This application has already been reviewed.' using errcode = '55000';
  end if;

  if p_decision = 'rejected' then
    update public.business_applications
    set status = 'rejected', reviewed_at = pg_catalog.now(), reviewed_by = auth.uid()
    where id = application_row.id;
    insert into public.audit_logs (actor_user_id, action, target_type, target_id, metadata)
    values (auth.uid(), 'business_application.rejected', 'business_application', application_row.id::text,
            pg_catalog.jsonb_build_object('status', 'rejected'));
    return null;
  end if;

  -- The applicant must first create and confirm an Auth account using the
  -- application email. This prevents ownership from being assigned by form data.
  select p.user_id into matched_owner_id
  from auth.users u
  join public.profiles p on p.user_id = u.id
  where pg_catalog.lower(u.email) = pg_catalog.lower(application_row.business_email)
    and u.email_confirmed_at is not null
  limit 1;
  if matched_owner_id is null then
    raise exception 'The applicant must register and confirm a LoyalLoop account using the business email before approval.'
      using errcode = 'P0001';
  end if;

  base_slug := pg_catalog.regexp_replace(
    pg_catalog.lower(application_row.business_name), '[^a-z0-9]+', '-', 'g');
  base_slug := pg_catalog.regexp_replace(base_slug, '(^-+|-+$)', '', 'g');
  if base_slug = '' then base_slug := 'business'; end if;
  base_slug := pg_catalog.left(base_slug, 70);
  candidate_slug := base_slug;
  while exists (select 1 from public.businesses b where b.slug = candidate_slug) loop
    candidate_slug := pg_catalog.left(base_slug, 70 - pg_catalog.char_length(suffix::text) - 1) || '-' || suffix::text;
    suffix := suffix + 1;
  end loop;

  new_business_id := public.admin_create_business(
    candidate_slug,
    application_row.business_name,
    application_row.category,
    application_row.business_email,
    application_row.contact_phone
  );
  perform public.admin_approve_business(new_business_id, matched_owner_id);

  update public.business_applications
  set status = 'approved', reviewed_at = pg_catalog.now(), reviewed_by = auth.uid(), business_id = new_business_id
  where id = application_row.id;
  insert into public.audit_logs (actor_user_id, business_id, action, target_type, target_id, metadata)
  values (auth.uid(), new_business_id, 'business_application.approved', 'business_application', application_row.id::text,
          pg_catalog.jsonb_build_object('status', 'approved', 'business_id', new_business_id));
  return new_business_id;
end;
$$;

revoke all on function public.submit_business_application(text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.submit_business_application(text, text, text, text, text, text) to anon, authenticated;
revoke all on function public.review_business_application(uuid, text) from public, anon, authenticated;
grant execute on function public.review_business_application(uuid, text) to authenticated;
