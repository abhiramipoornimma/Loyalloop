-- RLS policies, explicit API grants, and a public-business-logo bucket.

alter table public.profiles enable row level security;
alter table public.platform_admins enable row level security;
alter table public.businesses enable row level security;
alter table public.business_details enable row level security;
alter table public.business_branding enable row level security;
alter table public.business_memberships enable row level security;
alter table public.customer_profiles enable row level security;
alter table public.loyalty_programs enable row level security;
alter table public.reward_rules enable row level security;
alter table public.customer_loyalty_memberships enable row level security;
alter table public.stamp_transactions enable row level security;
alter table public.reward_redemptions enable row level security;
alter table public.business_offers enable row level security;
alter table public.business_subscriptions enable row level security;
alter table public.audit_logs enable row level security;

revoke all on table public.profiles, public.platform_admins, public.businesses, public.business_details,
  public.business_branding, public.business_memberships, public.customer_profiles,
  public.loyalty_programs, public.reward_rules, public.customer_loyalty_memberships,
  public.stamp_transactions, public.reward_redemptions, public.business_offers,
  public.business_subscriptions, public.audit_logs from public, anon, authenticated;

create policy profiles_select_self on public.profiles
  for select to authenticated using (user_id = (select auth.uid()));
create policy profiles_update_self on public.profiles
  for update to authenticated using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy platform_admins_select_admin on public.platform_admins
  for select to authenticated using (loyalloop_private.is_platform_admin());

create policy businesses_public_read on public.businesses
  for select to anon, authenticated
  using (loyalloop_private.is_public_business(id));
create policy businesses_member_read on public.businesses
  for select to authenticated
  using (loyalloop_private.has_business_role(id, 'owner')
    or loyalloop_private.has_business_role(id, 'staff')
    or loyalloop_private.is_platform_admin());
create policy businesses_owner_update on public.businesses
  for update to authenticated
  using (loyalloop_private.has_business_role(id, 'owner'))
  with check (loyalloop_private.has_business_role(id, 'owner'));
create policy businesses_admin_read_all on public.businesses
  for select to authenticated using (loyalloop_private.is_platform_admin());

create policy business_branding_public_read on public.business_branding
  for select to anon, authenticated
  using (loyalloop_private.is_public_business(business_id));
create policy business_branding_member_read on public.business_branding
  for select to authenticated
  using (loyalloop_private.has_business_role(business_id, 'owner')
    or loyalloop_private.has_business_role(business_id, 'staff')
    or loyalloop_private.is_platform_admin());
create policy business_branding_owner_insert on public.business_branding
  for insert to authenticated with check (loyalloop_private.has_business_role(business_id, 'owner'));
create policy business_branding_owner_update on public.business_branding
  for update to authenticated
  using (loyalloop_private.has_business_role(business_id, 'owner'))
  with check (loyalloop_private.has_business_role(business_id, 'owner'));

create policy business_details_owner_admin_read on public.business_details
  for select to authenticated
  using (loyalloop_private.has_business_role(business_id, 'owner')
    or loyalloop_private.is_platform_admin());
create policy business_details_owner_update_contact on public.business_details
  for update to authenticated
  using (loyalloop_private.has_business_role(business_id, 'owner'))
  with check (loyalloop_private.has_business_role(business_id, 'owner'));

create policy business_memberships_read_self_owner_admin on public.business_memberships
  for select to authenticated
  using (user_id = (select auth.uid())
    or loyalloop_private.has_business_role(business_id, 'owner')
    or loyalloop_private.is_platform_admin());
create policy business_memberships_owner_add_staff on public.business_memberships
  for insert to authenticated
  with check (role = 'staff' and status = 'active' and created_by = (select auth.uid())
    and loyalloop_private.has_business_role(business_id, 'owner'));
create policy business_memberships_owner_update_staff on public.business_memberships
  for update to authenticated
  using (role = 'staff' and loyalloop_private.has_business_role(business_id, 'owner'))
  with check (role = 'staff' and loyalloop_private.has_business_role(business_id, 'owner'));
create policy business_memberships_owner_delete_staff on public.business_memberships
  for delete to authenticated
  using (role = 'staff' and loyalloop_private.has_business_role(business_id, 'owner'));
create policy customer_profiles_read_self_or_business on public.customer_profiles
  for select to authenticated
  using (loyalloop_private.can_view_customer_profile(user_id));
-- phone_verified_at is provider-controlled; customers have no writable columns
-- in this table. Keep it read-only through the client API.

create policy loyalty_programs_public_read on public.loyalty_programs
  for select to anon, authenticated
  using (status = 'active' and loyalloop_private.is_public_business(business_id));
create policy loyalty_programs_member_read on public.loyalty_programs
  for select to authenticated
  using (loyalloop_private.has_business_role(business_id, 'owner')
    or loyalloop_private.has_business_role(business_id, 'staff')
    or loyalloop_private.is_platform_admin());
create policy loyalty_programs_owner_insert on public.loyalty_programs
  for insert to authenticated
  with check (status = 'draft' and loyalloop_private.has_business_role(business_id, 'owner'));
create policy loyalty_programs_owner_update on public.loyalty_programs
  for update to authenticated
  using (loyalloop_private.has_business_role(business_id, 'owner'))
  with check (loyalloop_private.has_business_role(business_id, 'owner'));
create policy loyalty_programs_admin_update on public.loyalty_programs
  for update to authenticated
  using (loyalloop_private.is_platform_admin())
  with check (loyalloop_private.is_platform_admin());

create policy reward_rules_public_active_read on public.reward_rules
  for select to anon, authenticated
  using (is_active and exists (
    select 1 from public.loyalty_programs lp
    where lp.id = program_id and lp.business_id = reward_rules.business_id
      and lp.status = 'active' and loyalloop_private.is_public_business(lp.business_id)
  ));
create policy reward_rules_member_read on public.reward_rules
  for select to authenticated
  using (loyalloop_private.has_business_role(business_id, 'owner')
    or loyalloop_private.has_business_role(business_id, 'staff')
    or loyalloop_private.is_platform_admin());

create policy customer_loyalty_memberships_read_customer_business on public.customer_loyalty_memberships
  for select to authenticated
  using (customer_user_id = (select auth.uid())
    or loyalloop_private.has_business_permission(business_id, 'view_customer_data')
    or loyalloop_private.is_platform_admin());
create policy stamp_transactions_read_customer_business on public.stamp_transactions
  for select to authenticated
  using (
    exists (
      select 1 from public.customer_loyalty_memberships clm
      where clm.business_id = stamp_transactions.business_id
        and clm.id = stamp_transactions.loyalty_membership_id
        and clm.customer_user_id = (select auth.uid())
    )
    or loyalloop_private.has_business_permission(business_id, 'view_customer_data')
    or loyalloop_private.is_platform_admin()
  );
create policy reward_redemptions_read_customer_business on public.reward_redemptions
  for select to authenticated
  using (
    exists (
      select 1 from public.customer_loyalty_memberships clm
      where clm.business_id = reward_redemptions.business_id
        and clm.id = reward_redemptions.loyalty_membership_id
        and clm.customer_user_id = (select auth.uid())
    )
    or loyalloop_private.has_business_permission(business_id, 'view_customer_data')
    or loyalloop_private.is_platform_admin()
  );

create policy business_offers_public_read on public.business_offers
  for select to anon, authenticated
  using (is_public and status = 'active'
    and (starts_at is null or starts_at <= now())
    and (ends_at is null or ends_at > now())
    and loyalloop_private.is_public_business(business_id));
create policy business_offers_member_read on public.business_offers
  for select to authenticated
  using (loyalloop_private.has_business_role(business_id, 'owner')
    or loyalloop_private.has_business_role(business_id, 'staff')
    or loyalloop_private.is_platform_admin());
create policy business_offers_owner_insert on public.business_offers
  for insert to authenticated
  with check (created_by = (select auth.uid())
    and loyalloop_private.has_business_role(business_id, 'owner'));
create policy business_offers_owner_update on public.business_offers
  for update to authenticated
  using (loyalloop_private.has_business_role(business_id, 'owner'))
  with check (loyalloop_private.has_business_role(business_id, 'owner'));
create policy business_offers_owner_delete on public.business_offers
  for delete to authenticated
  using (loyalloop_private.has_business_role(business_id, 'owner'));

create policy business_subscriptions_owner_admin_read on public.business_subscriptions
  for select to authenticated
  using (loyalloop_private.has_business_role(business_id, 'owner')
    or loyalloop_private.is_platform_admin());

create policy audit_logs_owner_admin_read on public.audit_logs
  for select to authenticated
  using (loyalloop_private.is_platform_admin()
    or (business_id is not null and loyalloop_private.has_business_role(business_id, 'owner')));

-- Public business selects expose only public columns; private contacts and approval
-- metadata are not granted to anon. Authenticated owners/admins may read full rows.
grant select (id, slug, display_name, category, status) on public.businesses to anon;
grant select (id, slug, display_name, category, status) on public.businesses to authenticated;
grant update (display_name, slug, category) on public.businesses to authenticated;
grant select on public.business_details to authenticated;
grant update (contact_email, contact_phone) on public.business_details to authenticated;
grant select on public.business_branding to anon, authenticated;
grant insert (business_id, logo_path, background_color, primary_color, secondary_color, text_color, theme_name, welcome_message, description)
  on public.business_branding to authenticated;
grant update (logo_path, background_color, primary_color, secondary_color, text_color, theme_name, welcome_message, description)
  on public.business_branding to authenticated;
grant select on public.profiles, public.customer_profiles to authenticated;
grant update (full_name, phone) on public.profiles to authenticated;
grant select on public.platform_admins to authenticated;
grant select on public.business_memberships to authenticated;
grant insert (business_id, user_id, role, status, can_enroll_customers, can_award_stamps, can_redeem_rewards, created_by)
  on public.business_memberships to authenticated;
grant update (status, can_enroll_customers, can_award_stamps, can_redeem_rewards)
  on public.business_memberships to authenticated;
grant delete on public.business_memberships to authenticated;
grant select on public.loyalty_programs to anon, authenticated;
grant select (id, business_id, program_id, version, stamps_required, reward_name, description, reward_type, discount_percent, is_active, created_at)
  on public.reward_rules to anon;
grant select on public.reward_rules to authenticated;
-- Owners may create only a draft program with server defaults for all other
-- fields; publishing remains a validated SECURITY DEFINER workflow. Admins
-- may update the program name, but have no direct insert/delete grant.
grant insert (business_id, name) on public.loyalty_programs to authenticated;
grant update (name) on public.loyalty_programs to authenticated;
grant select on public.customer_loyalty_memberships, public.stamp_transactions, public.reward_redemptions to authenticated;
grant select (id, business_id, title, description, offer_type, value, terms, status, is_public, starts_at, ends_at, created_at, updated_at)
  on public.business_offers to anon;
grant select on public.business_offers to authenticated;
grant insert (business_id, title, description, offer_type, value, terms, status, is_public, starts_at, ends_at, created_by)
  on public.business_offers to authenticated;
grant update (title, description, offer_type, value, terms, status, is_public, starts_at, ends_at)
  on public.business_offers to authenticated;
grant delete on public.business_offers to authenticated;
grant select (id, business_id, plan_code, status, current_period_start, current_period_end, created_at, updated_at)
  on public.business_subscriptions to authenticated;
grant select on public.audit_logs to authenticated;

-- Logo objects use the first path segment as a business UUID. The bucket contains
-- public-facing brand assets only; never put customer or private documents here.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('business-logos', 'business-logos', false, 2097152, array['image/png', 'image/jpeg', 'image/webp'])
on conflict (id) do nothing;

do $$
begin
  if not exists (
    select 1 from storage.buckets
    where id = 'business-logos' and name = 'business-logos' and not public
      and file_size_limit = 2097152
      and allowed_mime_types = array['image/png', 'image/jpeg', 'image/webp']::text[]
  ) then
    raise exception 'Existing business-logos bucket has unexpected settings; review it before applying this migration.';
  end if;
end;
$$;

create policy loyal_loop_public_business_logo_read on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'business-logos'
    and case when (storage.foldername(name))[1] ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
      then loyalloop_private.is_public_business(((storage.foldername(name))[1])::uuid)
      else false end);
create policy loyal_loop_owner_business_logo_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'business-logos'
    and case when (storage.foldername(name))[1] ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
      then loyalloop_private.has_business_role(((storage.foldername(name))[1])::uuid, 'owner')
      else false end);
create policy loyal_loop_owner_business_logo_update on storage.objects
  for update to authenticated
  using (bucket_id = 'business-logos'
    and case when (storage.foldername(name))[1] ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
      then loyalloop_private.has_business_role(((storage.foldername(name))[1])::uuid, 'owner')
      else false end)
  with check (bucket_id = 'business-logos'
    and case when (storage.foldername(name))[1] ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
      then loyalloop_private.has_business_role(((storage.foldername(name))[1])::uuid, 'owner')
      else false end);
create policy loyal_loop_owner_business_logo_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'business-logos'
    and case when (storage.foldername(name))[1] ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
      then loyalloop_private.has_business_role(((storage.foldername(name))[1])::uuid, 'owner')
      else false end);


