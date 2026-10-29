begin;

alter table public.business_applications
  add column if not exists approved_owner_user_id uuid
  references auth.users(id) on delete restrict;

update public.business_applications ba
set approved_owner_user_id = (
  select bm.user_id
  from public.business_memberships bm
  join auth.users u on u.id = bm.user_id
  where bm.business_id = ba.business_id
    and bm.role = 'owner'
    and bm.status = 'active'
    and pg_catalog.lower(u.email) = pg_catalog.lower(ba.business_email)
  order by bm.created_at, bm.user_id
  limit 1
)
where ba.status = 'approved'
  and ba.approved_owner_user_id is null;

update public.business_applications ba
set approved_owner_user_id = (
  select u.id
  from auth.users u
  join public.profiles p on p.user_id = u.id
  where pg_catalog.lower(u.email) = pg_catalog.lower(ba.business_email)
    and u.email_confirmed_at is not null
  order by u.created_at, u.id
  limit 1
)
where ba.status = 'reviewed'
  and ba.approved_owner_user_id is null;

do $$
begin
  if exists (
    select 1 from public.business_applications
    where status in ('approved', 'reviewed') and approved_owner_user_id is null
  ) then
    raise exception 'An approved or reviewed application has no matching owner account. Resolve the application records before continuing.';
  end if;
end;
$$;

alter table public.business_applications
  drop constraint if exists business_applications_status_check;
alter table public.business_applications
  add constraint business_applications_status_check
  check (status in ('pending', 'reviewed', 'approved', 'rejected'));

alter table public.business_applications
  drop constraint if exists business_applications_review_state_check;
alter table public.business_applications
  add constraint business_applications_review_state_check check (
    (status = 'pending' and reviewed_at is null and reviewed_by is null
      and business_id is null and approved_owner_user_id is null)
    or (status = 'reviewed' and reviewed_at is not null and reviewed_by is not null
      and business_id is null and approved_owner_user_id is not null)
    or (status = 'approved' and reviewed_at is not null and reviewed_by is not null
      and business_id is not null and approved_owner_user_id is not null)
    or (status = 'rejected' and reviewed_at is not null and reviewed_by is not null
      and business_id is null and approved_owner_user_id is null)
  );

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

commit;
