-- Explicit privileged workflows. All writes occur in the function transaction;
-- callers cannot write to loyalty ledgers or assign privileged roles directly.

create function public.admin_create_business(
  p_slug text,
  p_display_name text,
  p_category text default null,
  p_contact_email text default null,
  p_contact_phone text default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
set row_security = off
as $$
declare
  new_business_id uuid;
begin
  if auth.uid() is null or not loyalloop_private.is_platform_admin() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  insert into public.businesses (slug, display_name, category)
  values (lower(btrim(p_slug)), btrim(p_display_name), nullif(btrim(p_category), ''))
  returning id into new_business_id;
  insert into public.business_details (business_id, contact_email, contact_phone, created_by)
  values (new_business_id, nullif(btrim(p_contact_email), ''), nullif(btrim(p_contact_phone), ''), auth.uid());
  insert into public.business_branding (business_id) values (new_business_id);
  insert into public.loyalty_programs (business_id) values (new_business_id);
  return new_business_id;
end;
$$;

create function public.admin_approve_business(
  p_business_id uuid,
  p_owner_user_id uuid
)
returns void
language plpgsql
security definer
set search_path = pg_catalog
set row_security = off
as $$
declare
  old_status public.business_status;
begin
  if auth.uid() is null or not loyalloop_private.is_platform_admin() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  select b.status into old_status from public.businesses b where b.id = p_business_id for update;
  if not found then raise exception 'Business not found' using errcode = 'P0002'; end if;
  if old_status = 'closed' then raise exception 'Closed businesses cannot be approved'; end if;
  if not exists (select 1 from public.business_details bd where bd.business_id = p_business_id) then
    raise exception 'Business details are missing; approval cannot proceed';
  end if;
  if not exists (select 1 from public.profiles p where p.user_id = p_owner_user_id) then
    raise exception 'Owner account not found' using errcode = 'P0002';
  end if;

  update public.business_details
  set approval_status = 'approved', approved_by = auth.uid(), approved_at = now()
  where business_id = p_business_id;
  update public.businesses set status = 'active' where id = p_business_id;

  insert into public.business_memberships (
    business_id, user_id, role, status,
    can_enroll_customers, can_award_stamps, can_redeem_rewards, created_by
  ) values (p_business_id, p_owner_user_id, 'owner', 'active', true, true, true, auth.uid())
  on conflict (business_id, user_id) do update
  set role = 'owner', status = 'active', can_enroll_customers = true,
      can_award_stamps = true, can_redeem_rewards = true, created_by = auth.uid();

end;
$$;

create function public.admin_set_business_status(
  p_business_id uuid,
  p_status public.business_status
)
returns void
language plpgsql
security definer
set search_path = pg_catalog
set row_security = off
as $$
declare
  resulting_status public.business_status;
begin
  if auth.uid() is null or not loyalloop_private.is_platform_admin() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if p_status not in ('active', 'paused', 'closed') then
    raise exception 'Invalid administrative business status';
  end if;
  update public.businesses
  set status = p_status
  where id = p_business_id
  returning status into resulting_status;
  if not found then raise exception 'Business not found' using errcode = 'P0002'; end if;
  if p_status = 'active' and not exists (
    select 1 from public.business_details bd where bd.business_id = p_business_id and bd.approval_status = 'approved'
  ) then raise exception 'Business must be approved before activation'; end if;
end;
$$;

create function public.publish_reward_rule(
  p_business_id uuid,
  p_stamps_required integer,
  p_reward_name text,
  p_description text default null,
  p_reward_type text default 'free_item',
  p_discount_percent integer default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
set row_security = off
as $$
declare
  program_row public.loyalty_programs%rowtype;
  next_version integer;
  new_rule_id uuid;
begin
  if auth.uid() is null or not loyalloop_private.has_business_role(p_business_id, 'owner') then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  perform b.id from public.businesses b where b.id = p_business_id for share;
  if not found then raise exception 'Business not found' using errcode = 'P0002'; end if;
  if not loyalloop_private.is_public_business(p_business_id) then
    raise exception 'Business must be approved and active to publish rules';
  end if;
  if p_stamps_required not between 1 and 1000
     or char_length(btrim(coalesce(p_reward_name, ''))) not between 1 and 120
     or char_length(coalesce(p_description, '')) > 500
     or p_reward_type not in ('free_item', 'discount', 'other')
     or (p_reward_type = 'discount' and (p_discount_percent is null or p_discount_percent not between 1 and 100))
     or (p_reward_type <> 'discount' and p_discount_percent is not null) then
    raise exception 'Invalid reward rule';
  end if;
  select * into program_row from public.loyalty_programs lp
  where lp.business_id = p_business_id for update;
  if not found then raise exception 'Loyalty program not found' using errcode = 'P0002'; end if;
  select coalesce(max(rr.version), 0) + 1 into next_version
  from public.reward_rules rr where rr.program_id = program_row.id;
  update public.reward_rules set is_active = false
  where program_id = program_row.id and is_active;
  insert into public.reward_rules (
    business_id, program_id, version, stamps_required, reward_name, description,
    reward_type, discount_percent, is_active, created_by
  ) values (
    p_business_id, program_row.id, next_version, p_stamps_required, btrim(p_reward_name),
    nullif(btrim(p_description), ''), p_reward_type, p_discount_percent, true, auth.uid()
  ) returning id into new_rule_id;
  update public.loyalty_programs set status = 'active' where id = program_row.id;
  insert into public.audit_logs (actor_user_id, business_id, action, target_type, target_id, metadata)
  values (auth.uid(), p_business_id, 'reward_rule.published', 'reward_rule', new_rule_id::text,
          jsonb_build_object('version', next_version));
  return new_rule_id;
end;
$$;

create function public.enroll_customer(
  p_business_id uuid,
  p_customer_user_id uuid,
  p_idempotency_key text
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
set row_security = off
as $$
declare
  caller_id uuid := auth.uid();
  target_id uuid;
  program_id uuid;
  membership_id uuid;
  existing_customer_id uuid;
begin
  if caller_id is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 1 and 149 then
    raise exception 'Invalid idempotency key';
  end if;
  target_id := coalesce(p_customer_user_id, caller_id);
  if target_id <> caller_id
     and not loyalloop_private.has_business_permission(p_business_id, 'enroll_customers') then
    raise exception 'Not authorized to enroll this customer' using errcode = '42501';
  end if;
  perform b.id from public.businesses b where b.id = p_business_id for share;
  if not found then raise exception 'Business not found' using errcode = 'P0002'; end if;
  if not loyalloop_private.is_public_business(p_business_id) then
    raise exception 'Business is not active and approved';
  end if;
  select lp.id into program_id from public.loyalty_programs lp
  where lp.business_id = p_business_id and lp.status = 'active';
  if program_id is null then raise exception 'No active loyalty program'; end if;
  if not exists (select 1 from public.customer_profiles cp where cp.user_id = target_id) then
    raise exception 'Customer account not found' using errcode = 'P0002';
  end if;

  select clm.id, clm.customer_user_id into membership_id, existing_customer_id
  from public.customer_loyalty_memberships clm
  where clm.business_id = p_business_id and clm.enrollment_idempotency_key = p_idempotency_key;
  if membership_id is not null then
    if existing_customer_id <> target_id then raise exception 'Idempotency key was used for another customer'; end if;
    return membership_id;
  end if;

  insert into public.customer_loyalty_memberships (
    business_id, customer_user_id, program_id, enrollment_idempotency_key, enrolled_by
  ) values (p_business_id, target_id, program_id, p_idempotency_key, caller_id)
  on conflict (business_id, customer_user_id) do nothing
  returning id into membership_id;

  if membership_id is null then
    select clm.id into membership_id from public.customer_loyalty_memberships clm
    where clm.business_id = p_business_id and clm.customer_user_id = target_id;
    if membership_id is null then raise exception 'Enrollment conflict; retry with the same idempotency key'; end if;
    return membership_id;
  end if;
  insert into public.audit_logs (actor_user_id, business_id, action, target_type, target_id)
  values (caller_id, p_business_id, 'customer.enrolled', 'customer_loyalty_membership', membership_id::text);
  return membership_id;
end;
$$;

create function public.award_stamp(
  p_loyalty_membership_id uuid,
  p_stamp_count integer,
  p_idempotency_key text,
  p_reference text default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
set row_security = off
as $$
declare
  caller_id uuid := auth.uid();
  membership_row public.customer_loyalty_memberships%rowtype;
  existing_row public.stamp_transactions%rowtype;
  new_transaction_id uuid;
begin
  if caller_id is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  -- The existing staff UI awards one stamp per action; keep this RPC equally narrow.
  if p_stamp_count is distinct from 1 or p_idempotency_key is null
     or char_length(p_idempotency_key) not between 1 and 160
     or char_length(coalesce(p_reference, '')) > 160 then raise exception 'Invalid stamp request'; end if;
  if left(p_idempotency_key, 11) = 'redemption:' then
    raise exception 'Stamp idempotency keys cannot use the reserved redemption prefix';
  end if;
  select * into membership_row from public.customer_loyalty_memberships clm
  where clm.id = p_loyalty_membership_id for update;
  if not found then raise exception 'Loyalty membership not found' using errcode = 'P0002'; end if;
  if not loyalloop_private.has_business_permission(membership_row.business_id, 'award_stamps') then
    raise exception 'Not authorized to award stamps' using errcode = '42501';
  end if;
  if membership_row.status <> 'active' or not loyalloop_private.is_public_business(membership_row.business_id)
     or not exists (select 1 from public.loyalty_programs lp where lp.id = membership_row.program_id and lp.status = 'active')
     or not exists (select 1 from public.reward_rules rr where rr.program_id = membership_row.program_id and rr.is_active) then
    raise exception 'Business, membership, or loyalty program is inactive';
  end if;
  perform b.id from public.businesses b where b.id = membership_row.business_id for share;
  if not found or not loyalloop_private.is_public_business(membership_row.business_id) then
    raise exception 'Business is no longer active';
  end if;

  select * into existing_row from public.stamp_transactions st
  where st.business_id = membership_row.business_id and st.idempotency_key = p_idempotency_key;
  if found then
    if existing_row.transaction_type = 'award'
       and existing_row.loyalty_membership_id = membership_row.id
       and existing_row.stamp_delta = p_stamp_count
       and existing_row.reference is not distinct from nullif(btrim(p_reference), '')
       and existing_row.performed_by = caller_id then return existing_row.id; end if;
    raise exception 'Idempotency key was already used for a different operation';
  end if;

  insert into public.stamp_transactions (
    business_id, loyalty_membership_id, transaction_type, stamp_delta,
    rule_version, reference, performed_by, idempotency_key
  ) values (
    membership_row.business_id, membership_row.id, 'award', p_stamp_count,
    (select rr.version from public.reward_rules rr where rr.program_id = membership_row.program_id and rr.is_active),
    nullif(btrim(p_reference), ''), caller_id, p_idempotency_key
  ) on conflict (business_id, idempotency_key) do nothing
  returning id into new_transaction_id;

  if new_transaction_id is null then
    select * into existing_row from public.stamp_transactions st
    where st.business_id = membership_row.business_id and st.idempotency_key = p_idempotency_key;
    if existing_row.transaction_type = 'award'
       and existing_row.loyalty_membership_id = membership_row.id
       and existing_row.stamp_delta = p_stamp_count
       and existing_row.reference is not distinct from nullif(btrim(p_reference), '')
       and existing_row.performed_by = caller_id then return existing_row.id; end if;
    raise exception 'Idempotency key was already used for a different operation';
  end if;
  insert into public.audit_logs (actor_user_id, business_id, action, target_type, target_id, metadata)
  values (caller_id, membership_row.business_id, 'stamp.awarded', 'stamp_transaction', new_transaction_id::text,
          jsonb_build_object('membership_id', membership_row.id, 'stamp_count', p_stamp_count));
  return new_transaction_id;
end;
$$;

create function public.redeem_reward(
  p_loyalty_membership_id uuid,
  p_idempotency_key text
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog
set row_security = off
as $$
declare
  caller_id uuid := auth.uid();
  membership_row public.customer_loyalty_memberships%rowtype;
  active_rule public.reward_rules%rowtype;
  current_balance bigint;
  new_redemption_id uuid;
  prior_redemption public.reward_redemptions%rowtype;
begin
  if caller_id is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 1 and 149 then
    raise exception 'Invalid idempotency key';
  end if;
  select * into membership_row from public.customer_loyalty_memberships clm
  where clm.id = p_loyalty_membership_id for update;
  if not found then raise exception 'Loyalty membership not found' using errcode = 'P0002'; end if;
  if not loyalloop_private.has_business_permission(membership_row.business_id, 'redeem_rewards') then
    raise exception 'Not authorized to redeem rewards' using errcode = '42501';
  end if;
  if membership_row.status <> 'active' or not loyalloop_private.is_public_business(membership_row.business_id)
     or not exists (select 1 from public.loyalty_programs lp where lp.id = membership_row.program_id and lp.status = 'active') then
    raise exception 'Business, membership, or loyalty program is inactive';
  end if;
  perform b.id from public.businesses b where b.id = membership_row.business_id for share;
  if not found or not loyalloop_private.is_public_business(membership_row.business_id) then
    raise exception 'Business is no longer active';
  end if;

  select * into prior_redemption from public.reward_redemptions rr
  where rr.business_id = membership_row.business_id and rr.idempotency_key = p_idempotency_key;
  if found then
    if prior_redemption.loyalty_membership_id = membership_row.id
       and prior_redemption.redeemed_by = caller_id then return prior_redemption.id; end if;
    raise exception 'Idempotency key was already used for a different operation';
  end if;

  select * into active_rule from public.reward_rules rr
  where rr.program_id = membership_row.program_id and rr.is_active for share;
  if not found then raise exception 'No active reward rule'; end if;
  select coalesce(sum(st.stamp_delta), 0) into current_balance
  from public.stamp_transactions st
  where st.business_id = membership_row.business_id and st.loyalty_membership_id = membership_row.id;
  if current_balance < active_rule.stamps_required then raise exception 'Not enough stamps for this reward'; end if;

  insert into public.reward_redemptions (
    business_id, loyalty_membership_id, reward_rule_id, reward_name_snapshot,
    stamps_redeemed, redeemed_by, idempotency_key
  ) values (
    membership_row.business_id, membership_row.id, active_rule.id, active_rule.reward_name,
    active_rule.stamps_required, caller_id, p_idempotency_key
  ) on conflict (business_id, idempotency_key) do nothing
  returning id into new_redemption_id;
  if new_redemption_id is null then
    select * into prior_redemption from public.reward_redemptions rr
    where rr.business_id = membership_row.business_id and rr.idempotency_key = p_idempotency_key;
    if prior_redemption.loyalty_membership_id = membership_row.id
       and prior_redemption.redeemed_by = caller_id then return prior_redemption.id; end if;
    raise exception 'Idempotency key was already used for a different operation';
  end if;

  insert into public.stamp_transactions (
    business_id, loyalty_membership_id, transaction_type, stamp_delta,
    reward_redemption_id, rule_version, performed_by, idempotency_key
  ) values (
    membership_row.business_id, membership_row.id, 'redemption', -active_rule.stamps_required,
    new_redemption_id, active_rule.version, caller_id, 'redemption:' || p_idempotency_key
  );
  insert into public.audit_logs (actor_user_id, business_id, action, target_type, target_id, metadata)
  values (caller_id, membership_row.business_id, 'reward.redeemed', 'reward_redemption', new_redemption_id::text,
          jsonb_build_object('membership_id', membership_row.id, 'stamps_redeemed', active_rule.stamps_required));
  return new_redemption_id;
end;
$$;

revoke all on function public.admin_create_business(text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.admin_approve_business(uuid, uuid) from public, anon, authenticated;
revoke all on function public.admin_set_business_status(uuid, public.business_status) from public, anon, authenticated;
revoke all on function public.publish_reward_rule(uuid, integer, text, text, text, integer) from public, anon, authenticated;
revoke all on function public.enroll_customer(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.award_stamp(uuid, integer, text, text) from public, anon, authenticated;
revoke all on function public.redeem_reward(uuid, text) from public, anon, authenticated;
grant execute on function public.admin_create_business(text, text, text, text, text) to authenticated;
grant execute on function public.admin_approve_business(uuid, uuid) to authenticated;
grant execute on function public.admin_set_business_status(uuid, public.business_status) to authenticated;
grant execute on function public.publish_reward_rule(uuid, integer, text, text, text, integer) to authenticated;
grant execute on function public.enroll_customer(uuid, uuid, text) to authenticated;
grant execute on function public.award_stamp(uuid, integer, text, text) to authenticated;
grant execute on function public.redeem_reward(uuid, text) to authenticated;


