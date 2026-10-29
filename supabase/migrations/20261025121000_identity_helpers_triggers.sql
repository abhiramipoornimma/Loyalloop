-- Profile provisioning and narrowly scoped authorization helpers.

create function loyalloop_private.provision_auth_user_profile()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  supplied_name text;
begin
  -- Only a display name is copied from signup metadata. Role metadata is ignored.
  supplied_name := left(btrim(coalesce(new.raw_user_meta_data ->> 'full_name', '')), 120);
  insert into public.profiles (user_id, full_name)
  values (new.id, supplied_name)
  on conflict (user_id) do nothing;
  insert into public.customer_profiles (user_id)
  values (new.id)
  on conflict (user_id) do nothing;
  return new;
end;
$$;

create trigger loyalloop_auth_user_profile_after_insert
  after insert on auth.users
  for each row execute function loyalloop_private.provision_auth_user_profile();

-- Bring pre-existing Auth users into line with the signup trigger. Existing
-- profile values are preserved; all Auth users are customer-capable by design.
insert into public.profiles (user_id, full_name)
select u.id, left(btrim(coalesce(u.raw_user_meta_data ->> 'full_name', '')), 120)
from auth.users u
on conflict (user_id) do nothing;

insert into public.customer_profiles (user_id)
select u.id from auth.users u
on conflict (user_id) do nothing;

create trigger profiles_touch_updated_at before update on public.profiles
  for each row execute function loyalloop_private.touch_updated_at();
create trigger platform_admins_touch_updated_at before update on public.platform_admins
  for each row execute function loyalloop_private.touch_updated_at();
create trigger businesses_touch_updated_at before update on public.businesses
  for each row execute function loyalloop_private.touch_updated_at();
create trigger business_details_touch_updated_at before update on public.business_details
  for each row execute function loyalloop_private.touch_updated_at();
create trigger business_branding_touch_updated_at before update on public.business_branding
  for each row execute function loyalloop_private.touch_updated_at();
create trigger business_memberships_touch_updated_at before update on public.business_memberships
  for each row execute function loyalloop_private.touch_updated_at();
create trigger customer_profiles_touch_updated_at before update on public.customer_profiles
  for each row execute function loyalloop_private.touch_updated_at();
create trigger loyalty_programs_touch_updated_at before update on public.loyalty_programs
  for each row execute function loyalloop_private.touch_updated_at();
create trigger customer_loyalty_memberships_touch_updated_at before update on public.customer_loyalty_memberships
  for each row execute function loyalloop_private.touch_updated_at();
create trigger business_offers_touch_updated_at before update on public.business_offers
  for each row execute function loyalloop_private.touch_updated_at();
create trigger business_subscriptions_touch_updated_at before update on public.business_subscriptions
  for each row execute function loyalloop_private.touch_updated_at();

create function loyalloop_private.audit_row_change()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
set row_security = off
as $$
declare
  before_row jsonb;
  after_row jsonb;
  row_data jsonb;
  changed_fields text[];
  affected_business_id uuid;
  affected_target_id text;
begin
  if tg_op <> 'INSERT' then before_row := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then after_row := to_jsonb(new); end if;
  row_data := coalesce(after_row, before_row);
  if tg_table_name = 'businesses' then
    affected_business_id := (row_data ->> 'id')::uuid;
  elsif row_data ? 'business_id' then
    affected_business_id := (row_data ->> 'business_id')::uuid;
  end if;
  affected_target_id := coalesce(row_data ->> 'id', row_data ->> 'user_id');
  select coalesce(array_agg(k.key order by k.key), array[]::text[])
    into changed_fields
  from jsonb_object_keys(coalesce(after_row, before_row)) as k(key)
  where after_row -> k.key is distinct from before_row -> k.key;

  insert into public.audit_logs (business_id, actor_user_id, action, target_type, target_id, metadata)
  values (
    affected_business_id,
    auth.uid(),
    lower(replace(tg_table_name, '_', '')) || '.' || lower(tg_op),
    tg_table_name,
    affected_target_id,
    jsonb_build_object('changed_fields', changed_fields)
  );
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

create trigger businesses_audit_changes after insert or update or delete on public.businesses
  for each row execute function loyalloop_private.audit_row_change();
create trigger business_details_audit_changes after insert or update or delete on public.business_details
  for each row execute function loyalloop_private.audit_row_change();
create trigger platform_admins_audit_changes after insert or update or delete on public.platform_admins
  for each row execute function loyalloop_private.audit_row_change();
create trigger business_branding_audit_changes after insert or update or delete on public.business_branding
  for each row execute function loyalloop_private.audit_row_change();
create trigger business_memberships_audit_changes after insert or update or delete on public.business_memberships
  for each row execute function loyalloop_private.audit_row_change();
create trigger loyalty_programs_audit_changes after insert or update or delete on public.loyalty_programs
  for each row execute function loyalloop_private.audit_row_change();
create trigger business_offers_audit_changes after insert or update or delete on public.business_offers
  for each row execute function loyalloop_private.audit_row_change();
create trigger business_subscriptions_audit_changes after insert or update or delete on public.business_subscriptions
  for each row execute function loyalloop_private.audit_row_change();

create function loyalloop_private.is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
set row_security = off
as $$
  select exists (
    select 1 from public.platform_admins pa
    where pa.user_id = auth.uid() and pa.is_active
  );
$$;

create function loyalloop_private.has_business_role(p_business_id uuid, p_role text)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
set row_security = off
as $$
  select auth.uid() is not null and exists (
    select 1 from public.business_memberships bm
    where bm.business_id = p_business_id
      and bm.user_id = auth.uid()
      and bm.status = 'active'
      and bm.role::text = p_role
  );
$$;

create function loyalloop_private.has_business_permission(p_business_id uuid, p_permission text)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
set row_security = off
as $$
  select auth.uid() is not null and exists (
    select 1 from public.business_memberships bm
    where bm.business_id = p_business_id
      and bm.user_id = auth.uid()
      and bm.status = 'active'
      and (
        bm.role = 'owner'
        or (bm.role = 'staff' and case p_permission
          when 'enroll_customers' then bm.can_enroll_customers
          when 'award_stamps' then bm.can_award_stamps
          when 'redeem_rewards' then bm.can_redeem_rewards
          when 'view_customer_data' then (bm.can_enroll_customers or bm.can_award_stamps or bm.can_redeem_rewards)
          else false
        end)
      )
  );
$$;

create function loyalloop_private.is_public_business(p_business_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
set row_security = off
as $$
  select exists (
    select 1 from public.businesses b
    join public.business_details bd on bd.business_id = b.id
    where b.id = p_business_id
      and b.status = 'active'
      and bd.approval_status = 'approved'
  );
$$;

create function loyalloop_private.can_view_customer_profile(p_customer_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
set row_security = off
as $$
  select auth.uid() = p_customer_user_id
    or exists (
      select 1
      from public.customer_loyalty_memberships clm
      where clm.customer_user_id = p_customer_user_id
        and loyalloop_private.has_business_permission(clm.business_id, 'view_customer_data')
    );
$$;

-- Policies call these functions; they reveal only the current caller's access decision.
revoke all on function loyalloop_private.provision_auth_user_profile() from public, anon, authenticated;
revoke all on function loyalloop_private.audit_row_change() from public, anon, authenticated;

revoke all on function loyalloop_private.is_platform_admin() from public, anon, authenticated;
revoke all on function loyalloop_private.has_business_role(uuid, text) from public, anon, authenticated;
revoke all on function loyalloop_private.has_business_permission(uuid, text) from public, anon, authenticated;
revoke all on function loyalloop_private.is_public_business(uuid) from public, anon, authenticated;
revoke all on function loyalloop_private.can_view_customer_profile(uuid) from public, anon, authenticated;
revoke all on function loyalloop_private.touch_updated_at() from public, anon, authenticated;
grant usage on schema loyalloop_private to anon, authenticated;
grant execute on function loyalloop_private.is_platform_admin() to authenticated;
grant execute on function loyalloop_private.has_business_role(uuid, text) to authenticated;
grant execute on function loyalloop_private.has_business_permission(uuid, text) to authenticated;
grant execute on function loyalloop_private.is_public_business(uuid) to anon, authenticated;
grant execute on function loyalloop_private.can_view_customer_profile(uuid) to authenticated;

