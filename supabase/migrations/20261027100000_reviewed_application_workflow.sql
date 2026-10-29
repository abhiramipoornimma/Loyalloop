begin;

-- Introduce "reviewed" as the post-review application status without recreating
-- the table or breaking existing pending/approved/rejected records.
alter table public.business_applications drop constraint if exists business_applications_status_check;
alter table public.business_applications
  add constraint business_applications_status_check
  check (status in ('pending', 'reviewed', 'approved', 'rejected'));

-- Preserve existing approved rows (they already linked a business/owner).
-- New reviews set "reviewed" and never create a business or grant owner access.
alter table public.business_applications drop constraint if exists business_applications_review_state_check;
alter table public.business_applications
  add constraint business_applications_review_state_check check (
    (status = 'pending' and reviewed_at is null and reviewed_by is null and business_id is null and approved_owner_user_id is null)
    or (status = 'reviewed' and reviewed_at is not null and reviewed_by is not null and business_id is null and approved_owner_user_id is null)
    or (status = 'approved' and reviewed_at is not null and reviewed_by is not null and approved_owner_user_id is not null)
    or (status = 'rejected' and reviewed_at is not null and reviewed_by is not null and business_id is null and approved_owner_user_id is null)
  );

-- Review now only updates status; no business/membership/subscription is created.
create or replace function public.review_business_application(p_application_id uuid, p_decision text)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
set row_security = off
as $$
declare
  application_row public.business_applications%rowtype;
  matched_owner_id uuid;
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
    return application_row.id;
  end if;

  -- Only verify a confirmed Auth account exists; do not create business or owner.
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

  update public.business_applications
  set status = 'reviewed', reviewed_at = pg_catalog.now(), reviewed_by = auth.uid(),
      approved_owner_user_id = matched_owner_id
  where id = application_row.id;
  insert into public.audit_logs (actor_user_id, action, target_type, target_id, metadata)
  values (auth.uid(), 'business_application.reviewed', 'business_application', application_row.id::text,
          pg_catalog.jsonb_build_object('status', 'reviewed', 'eligible_owner_user_id', matched_owner_id));
  return application_row.id;
end;
$$;

-- Allow admin business creation from reviewed (or legacy approved) applications.
create or replace function public.admin_create_business_with_owner(p_slug text, p_display_name text, p_category text, p_contact_email text)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
set row_security = off
as $$
declare
  caller_id uuid := auth.uid();
  normalized_slug text := pg_catalog.lower(pg_catalog.btrim(p_slug));
  normalized_email text := pg_catalog.lower(pg_catalog.btrim(p_contact_email));
  application_row public.business_applications%rowtype;
  new_business_id uuid;
begin
  if caller_id is null or not loyalloop_private.is_platform_admin() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if p_slug is null or p_display_name is null or p_category is null or p_contact_email is null
     or normalized_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' or pg_catalog.char_length(normalized_slug) > 80
     or pg_catalog.char_length(pg_catalog.btrim(p_display_name)) not between 1 and 120
     or pg_catalog.char_length(pg_catalog.btrim(p_category)) not between 1 and 80
     or pg_catalog.char_length(normalized_email) not between 3 and 254
     or normalized_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception 'Business details are invalid.' using errcode = '22023';
  end if;

  select * into application_row
  from public.business_applications ba
  where ba.status in ('reviewed', 'approved')
    and ba.business_id is null
    and ba.approved_owner_user_id is not null
    and pg_catalog.lower(ba.business_email) = normalized_email
  order by ba.reviewed_at desc, ba.submitted_at desc
  limit 1
  for update;
  if not found then
    raise exception 'No reviewed application is available for this confirmed owner email.' using errcode = 'P0001';
  end if;
  if not exists (
    select 1 from auth.users u join public.profiles p on p.user_id = u.id
    where u.id = application_row.approved_owner_user_id
      and pg_catalog.lower(u.email) = normalized_email
      and u.email_confirmed_at is not null
  ) then
    raise exception 'The approved owner account is no longer confirmed for this email.' using errcode = 'P0001';
  end if;

  new_business_id := public.admin_create_business(
    normalized_slug, pg_catalog.btrim(p_display_name), pg_catalog.btrim(p_category),
    normalized_email, application_row.contact_phone
  );
  perform public.admin_approve_business(new_business_id, application_row.approved_owner_user_id);
  update public.business_applications
  set business_id = new_business_id
  where id = application_row.id and business_id is null;
  if not found then raise exception 'Application was already consumed.' using errcode = '55000'; end if;
  insert into public.audit_logs (actor_user_id, business_id, action, target_type, target_id, metadata)
  values (caller_id, new_business_id, 'business.created_from_application', 'business_application', application_row.id::text,
          pg_catalog.jsonb_build_object('application_id', application_row.id, 'owner_user_id', application_row.approved_owner_user_id));
  return new_business_id;
end;
$$;

revoke all on function public.review_business_application(uuid, text) from public, anon, authenticated;
grant execute on function public.review_business_application(uuid, text) to authenticated;
revoke all on function public.admin_create_business_with_owner(text, text, text, text) from public, anon, authenticated;
grant execute on function public.admin_create_business_with_owner(text, text, text, text) to authenticated;

commit;
