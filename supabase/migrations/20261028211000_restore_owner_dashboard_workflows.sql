begin;

create or replace function public.publish_reward_rule_with_terms(
  p_business_id uuid,
  p_stamps_required integer,
  p_reward_name text,
  p_description text default null,
  p_reward_type text default 'free_item',
  p_discount_percent integer default null,
  p_minimum_purchase numeric default null,
  p_validity_days integer default null,
  p_program_active boolean default true
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
    raise exception 'Not authorized to publish rewards' using errcode = '42501';
  end if;
  if not loyalloop_private.is_public_business(p_business_id) then
    raise exception 'Business must be approved and active to publish rules';
  end if;
  if p_stamps_required not between 1 and 1000
     or pg_catalog.char_length(pg_catalog.btrim(coalesce(p_reward_name, ''))) not between 1 and 120
     or pg_catalog.char_length(coalesce(p_description, '')) > 500
     or p_reward_type not in ('free_item', 'discount', 'other')
     or (p_reward_type = 'discount' and (p_discount_percent is null or p_discount_percent not between 1 and 100))
     or (p_reward_type <> 'discount' and p_discount_percent is not null)
     or (p_minimum_purchase is not null and p_minimum_purchase not between 0 and 99999999.99)
     or (p_validity_days is not null and p_validity_days not between 1 and 3650) then
    raise exception 'Invalid reward rule' using errcode = '22023';
  end if;

  select * into program_row
  from public.loyalty_programs
  where business_id = p_business_id
  for update;
  if not found then raise exception 'Loyalty program not found' using errcode = 'P0002'; end if;

  select coalesce(max(version), 0) + 1 into next_version
  from public.reward_rules
  where program_id = program_row.id;
  update public.reward_rules
  set is_active = false
  where program_id = program_row.id and is_active;

  insert into public.reward_rules (
    business_id, program_id, version, stamps_required, reward_name, description,
    reward_type, discount_percent, is_active, created_by, minimum_purchase,
    validity_days, valid_until
  ) values (
    p_business_id, program_row.id, next_version, p_stamps_required,
    pg_catalog.btrim(p_reward_name), nullif(pg_catalog.btrim(p_description), ''),
    p_reward_type, p_discount_percent, true, auth.uid(), p_minimum_purchase,
    p_validity_days,
    case when p_validity_days is null then null
      else pg_catalog.now() + p_validity_days * interval '1 day' end
  )
  returning id into new_rule_id;

  update public.loyalty_programs
  set status = case when p_program_active then 'active'::public.program_status
                    else 'paused'::public.program_status end
  where id = program_row.id;

  insert into public.audit_logs (actor_user_id, business_id, action, target_type, target_id, metadata)
  values (
    auth.uid(), p_business_id, 'reward_rule.published', 'reward_rule', new_rule_id::text,
    pg_catalog.jsonb_build_object(
      'version', next_version,
      'minimum_purchase', p_minimum_purchase,
      'validity_days', p_validity_days,
      'program_active', p_program_active
    )
  );
  return new_rule_id;
end;
$$;

revoke all on function public.publish_reward_rule_with_terms(
  uuid, integer, text, text, text, integer, numeric, integer, boolean
) from public, anon, authenticated;
grant execute on function public.publish_reward_rule_with_terms(
  uuid, integer, text, text, text, integer, numeric, integer, boolean
) to authenticated;

create or replace function public.set_loyalty_program_status(p_business_id uuid, p_status text)
returns public.program_status
language plpgsql
security definer
set search_path = pg_catalog
set row_security = off
as $$
declare
  program_row public.loyalty_programs%rowtype;
  new_status public.program_status;
begin
  if auth.uid() is null or not loyalloop_private.has_business_role(p_business_id, 'owner') then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if p_status is null or p_status not in ('active', 'paused') then
    raise exception 'Status must be active or paused.' using errcode = '22023';
  end if;

  select * into program_row
  from public.loyalty_programs
  where business_id = p_business_id
  for update;
  if not found then raise exception 'Loyalty program not found.' using errcode = 'P0002'; end if;

  if p_status = 'active' and not loyalloop_private.is_public_business(p_business_id) then
    raise exception 'Business must be approved and active before activating its loyalty programme.'
      using errcode = '55000';
  end if;
  if p_status = 'active' and not exists (
    select 1 from public.reward_rules rr
    where rr.program_id = program_row.id
      and rr.is_active
      and (rr.valid_until is null or rr.valid_until > pg_catalog.now())
  ) then
    raise exception 'Publish a current reward rule before activating the programme.' using errcode = '55000';
  end if;

  new_status := p_status::public.program_status;
  update public.loyalty_programs set status = new_status where id = program_row.id;
  insert into public.audit_logs (actor_user_id, business_id, action, target_type, target_id, metadata)
  values (
    auth.uid(), p_business_id, 'loyalty_program.status_changed',
    'loyalty_program', program_row.id::text,
    pg_catalog.jsonb_build_object('status', new_status)
  );
  return new_status;
end;
$$;

revoke all on function public.set_loyalty_program_status(uuid, text) from public, anon, authenticated;
grant execute on function public.set_loyalty_program_status(uuid, text) to authenticated;

create or replace function public.owner_save_business_settings(
  p_business_id uuid,
  p_display_name text,
  p_slug text,
  p_contact_email text,
  p_contact_phone text,
  p_program_status text
)
returns public.program_status
language plpgsql
security definer
set search_path = pg_catalog
set row_security = off
as $$
declare
  program_row public.loyalty_programs%rowtype;
  new_status public.program_status;
begin
  if auth.uid() is null or not loyalloop_private.has_business_role(p_business_id, 'owner') then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if pg_catalog.char_length(pg_catalog.btrim(coalesce(p_display_name, ''))) not between 1 and 120
     or pg_catalog.lower(pg_catalog.btrim(coalesce(p_slug, ''))) !~ '^[a-z0-9]+(-[a-z0-9]+)*$'
     or pg_catalog.char_length(pg_catalog.btrim(coalesce(p_slug, ''))) > 80
     or pg_catalog.char_length(pg_catalog.btrim(coalesce(p_contact_email, ''))) not between 3 and 254
     or pg_catalog.lower(pg_catalog.btrim(p_contact_email)) !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
     or pg_catalog.char_length(coalesce(p_contact_phone, '')) > 32 then
    raise exception 'Business settings are invalid.' using errcode = '22023';
  end if;
  if p_program_status is null or p_program_status not in ('active', 'paused') then
    raise exception 'Programme status must be active or paused.' using errcode = '22023';
  end if;

  update public.businesses
  set display_name = pg_catalog.btrim(p_display_name),
      slug = pg_catalog.lower(pg_catalog.btrim(p_slug))
  where id = p_business_id;
  if not found then raise exception 'Business not found.' using errcode = 'P0002'; end if;

  update public.business_details
  set contact_email = pg_catalog.lower(pg_catalog.btrim(p_contact_email)),
      contact_phone = nullif(pg_catalog.btrim(p_contact_phone), '')
  where business_id = p_business_id;
  if not found then raise exception 'Business details not found.' using errcode = 'P0002'; end if;

  select * into program_row
  from public.loyalty_programs
  where business_id = p_business_id
  for update;
  if not found then raise exception 'Loyalty program not found.' using errcode = 'P0002'; end if;
  if p_program_status = 'active' and not loyalloop_private.is_public_business(p_business_id) then
    raise exception 'Business must be approved and active before activating its loyalty programme.'
      using errcode = '55000';
  end if;
  if p_program_status = 'active' and not exists (
    select 1 from public.reward_rules rr
    where rr.program_id = program_row.id
      and rr.is_active
      and (rr.valid_until is null or rr.valid_until > pg_catalog.now())
  ) then
    raise exception 'Publish a current reward rule before activating the programme.' using errcode = '55000';
  end if;

  new_status := p_program_status::public.program_status;
  update public.loyalty_programs set status = new_status where id = program_row.id;
  insert into public.audit_logs (actor_user_id, business_id, action, target_type, target_id, metadata)
  values (
    auth.uid(), p_business_id, 'business.settings_updated',
    'business', p_business_id::text,
    pg_catalog.jsonb_build_object('program_status', new_status)
  );
  return new_status;
end;
$$;

revoke all on function public.owner_save_business_settings(uuid, text, text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.owner_save_business_settings(uuid, text, text, text, text, text)
  to authenticated;

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
    select 1 from public.business_memberships bm
    where bm.business_id = p_business_id
      and bm.user_id = p_owner_user_id
      and bm.role = 'owner'
      and bm.status = 'active'
  ) then
    raise exception 'The requesting account is not an active owner of this business.' using errcode = '42501';
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
    p_business_id, p_staff_user_id, 'staff', 'active', false,
    true, true, p_owner_user_id
  )
  returning id into membership_id;

  insert into public.audit_logs (actor_user_id, business_id, action, target_type, target_id, metadata)
  values (
    p_owner_user_id, p_business_id, 'staff.invited', 'business_membership',
    membership_id::text,
    pg_catalog.jsonb_build_object('staff_user_id', p_staff_user_id, 'role', 'staff')
  );
  return membership_id;
end;
$$;

revoke all on function public.owner_add_invited_staff(uuid, uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.owner_add_invited_staff(uuid, uuid, uuid) to service_role;

create or replace function public.reward_rule_validity_guard()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
set row_security = off
as $$
begin
  if exists (
    select 1 from public.reward_rules rr
    where rr.id = new.reward_rule_id
      and rr.valid_until is not null
      and rr.valid_until <= pg_catalog.now()
  ) then
    raise exception 'This reward offer has expired.' using errcode = '55000';
  end if;
  return new;
end;
$$;
revoke all on function public.reward_rule_validity_guard() from public, anon, authenticated;
drop trigger if exists reward_redemptions_valid_rule_before_insert on public.reward_redemptions;
create trigger reward_redemptions_valid_rule_before_insert
  before insert on public.reward_redemptions
  for each row execute function public.reward_rule_validity_guard();

create or replace function public.stamp_awards_valid_rule_guard()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
set row_security = off
as $$
begin
  if new.transaction_type = 'award' and exists (
    select 1
    from public.customer_loyalty_memberships clm
    join public.reward_rules rr on rr.program_id = clm.program_id and rr.is_active
    where clm.business_id = new.business_id
      and clm.id = new.loyalty_membership_id
      and rr.valid_until is not null
      and rr.valid_until <= pg_catalog.now()
  ) then
    raise exception 'The active reward offer has expired; publish a current rule before awarding stamps.'
      using errcode = '55000';
  end if;
  return new;
end;
$$;
revoke all on function public.stamp_awards_valid_rule_guard() from public, anon, authenticated;
drop trigger if exists stamp_transactions_valid_rule_before_insert on public.stamp_transactions;
create trigger stamp_transactions_valid_rule_before_insert
  before insert on public.stamp_transactions
  for each row execute function public.stamp_awards_valid_rule_guard();

drop policy if exists reward_rules_public_active_read on public.reward_rules;
create policy reward_rules_public_active_read on public.reward_rules
  for select to anon, authenticated
  using (
    is_active
    and (valid_until is null or valid_until > pg_catalog.now())
    and exists (
      select 1 from public.loyalty_programs lp
      where lp.id = program_id
        and lp.business_id = reward_rules.business_id
        and lp.status = 'active'
        and loyalloop_private.is_public_business(lp.business_id)
    )
  );
grant select (minimum_purchase, validity_days, valid_until)
  on public.reward_rules to anon, authenticated;

commit;
