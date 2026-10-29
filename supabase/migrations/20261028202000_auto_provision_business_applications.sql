begin;

create function loyalloop_private.provision_business_application(
  p_application_id uuid,
  p_actor_user_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
set row_security = off
as $$
declare
  application_row public.business_applications%rowtype;
  owner_user_id uuid;
  new_business_id uuid;
  base_slug text;
  candidate_slug text;
  suffix integer := 1;
begin
  select * into application_row
  from public.business_applications ba
  where ba.id = p_application_id
  for update;
  if not found then raise exception 'Application not found.' using errcode = 'P0002'; end if;
  if application_row.status not in ('pending', 'reviewed') then
    raise exception 'This application has already been reviewed.' using errcode = '55000';
  end if;
  if p_actor_user_id is null then
    raise exception 'A reviewing administrator is required.' using errcode = '22023';
  end if;

  select u.id into owner_user_id
  from auth.users u
  join public.profiles p on p.user_id = u.id
  where pg_catalog.lower(u.email) = pg_catalog.lower(application_row.business_email)
    and u.email_confirmed_at is not null
    and (application_row.approved_owner_user_id is null or u.id = application_row.approved_owner_user_id)
  limit 1;
  if owner_user_id is null then
    raise exception 'The applicant must register and confirm a LoyalLoop account using the business email before acceptance.'
      using errcode = 'P0001';
  end if;

  base_slug := pg_catalog.regexp_replace(
    pg_catalog.lower(application_row.business_name), '[^a-z0-9]+', '-', 'g');
  base_slug := pg_catalog.regexp_replace(base_slug, '(^-+|-+$)', '', 'g');
  if base_slug = '' then base_slug := 'business'; end if;
  base_slug := pg_catalog.left(base_slug, 70);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(base_slug, 0));
  candidate_slug := base_slug;
  while exists (select 1 from public.businesses b where b.slug = candidate_slug) loop
    candidate_slug := pg_catalog.left(base_slug, 78 - pg_catalog.char_length(suffix::text))
      || '-' || suffix::text;
    suffix := suffix + 1;
  end loop;

  insert into public.businesses (slug, display_name, category, status)
  values (candidate_slug, application_row.business_name, application_row.category, 'pending')
  returning id into new_business_id;

  insert into public.business_details (business_id, contact_email, contact_phone, created_by)
  values (new_business_id, application_row.business_email, application_row.contact_phone, p_actor_user_id);
  insert into public.business_branding (business_id) values (new_business_id);
  insert into public.loyalty_programs (business_id) values (new_business_id);

  update public.business_details
  set approval_status = 'approved', approved_by = p_actor_user_id, approved_at = pg_catalog.now()
  where business_id = new_business_id;
  update public.businesses set status = 'active' where id = new_business_id;

  insert into public.business_memberships (
    business_id, user_id, role, status,
    can_enroll_customers, can_award_stamps, can_redeem_rewards, created_by
  ) values (
    new_business_id, owner_user_id, 'owner', 'active',
    true, true, true, p_actor_user_id
  );

  update public.business_applications
  set status = 'approved',
      reviewed_at = coalesce(reviewed_at, pg_catalog.now()),
      reviewed_by = p_actor_user_id,
      approved_owner_user_id = owner_user_id,
      business_id = new_business_id
  where id = application_row.id;

  insert into public.audit_logs (actor_user_id, business_id, action, target_type, target_id, metadata)
  values (
    p_actor_user_id, new_business_id, 'business_application.approved',
    'business_application', application_row.id::text,
    pg_catalog.jsonb_build_object('status', 'approved', 'business_id', new_business_id)
  );
  return new_business_id;
end;
$$;

revoke all on function loyalloop_private.provision_business_application(uuid, uuid)
  from public, anon, authenticated;

create or replace function public.review_business_application(p_application_id uuid, p_decision text)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
set row_security = off
as $$
declare
  application_row public.business_applications%rowtype;
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

  return loyalloop_private.provision_business_application(application_row.id, auth.uid());
end;
$$;

revoke all on function public.review_business_application(uuid, text) from public, anon, authenticated;
grant execute on function public.review_business_application(uuid, text) to authenticated;

do $$
declare
  reviewed_application record;
begin
  for reviewed_application in
    select ba.id, ba.reviewed_by
    from public.business_applications ba
    where ba.status = 'reviewed'
    order by ba.submitted_at, ba.id
  loop
    perform loyalloop_private.provision_business_application(
      reviewed_application.id, reviewed_application.reviewed_by);
  end loop;
end;
$$;

drop function if exists public.admin_create_business_with_owner(text, text, text, text);

commit;
