begin;

update public.business_memberships
set can_enroll_customers = true
where role = 'staff'
  and status = 'active'
  and not can_enroll_customers;

create or replace function public.owner_add_invited_staff(
  p_business_id uuid,
  p_owner_user_id uuid,
  p_staff_user_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
set row_security = off
as $$
declare
  membership_id uuid;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if not exists (
    select 1
    from public.business_memberships bm
    where bm.business_id = p_business_id
      and bm.user_id = p_owner_user_id
      and bm.role = 'owner'
      and bm.status = 'active'
  ) then
    raise exception 'The requesting account is not an active owner of this business.'
      using errcode = '42501';
  end if;
  if not exists (
    select 1
    from public.businesses b
    join public.business_details bd on bd.business_id = b.id
    where b.id = p_business_id
      and b.status = 'active'
      and bd.approval_status = 'approved'
  ) then
    raise exception 'Business is not approved and active.' using errcode = '55000';
  end if;

  insert into public.business_memberships (
    business_id, user_id, role, status, can_enroll_customers,
    can_award_stamps, can_redeem_rewards, created_by
  ) values (
    p_business_id, p_staff_user_id, 'staff', 'active', true,
    true, true, p_owner_user_id
  )
  returning id into membership_id;

  insert into public.audit_logs (
    actor_user_id, business_id, action, target_type, target_id, metadata
  ) values (
    p_owner_user_id, p_business_id, 'staff.invited', 'business_membership',
    membership_id::text,
    pg_catalog.jsonb_build_object('staff_user_id', p_staff_user_id, 'role', 'staff')
  );
  return membership_id;
end;
$$;

revoke all on function public.owner_add_invited_staff(uuid, uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.owner_add_invited_staff(uuid, uuid, uuid)
  to service_role;

commit;
