-- LoyalLoop core schema. This migration defines data structures only; it does
-- not provision users, businesses, credentials, or sample customer data.

create schema loyalloop_private;
revoke all on schema loyalloop_private from public;

create type public.business_status as enum ('pending', 'active', 'paused', 'closed');
create type public.business_approval_status as enum ('pending', 'approved', 'rejected');
create type public.business_member_role as enum ('owner', 'staff');
create type public.membership_status as enum ('active', 'inactive');
create type public.program_status as enum ('draft', 'active', 'paused');
create type public.offer_status as enum ('draft', 'active', 'paused', 'archived');
create type public.subscription_status as enum ('trialing', 'active', 'past_due', 'paused', 'cancelled', 'expired');
create type public.stamp_transaction_type as enum ('award', 'redemption');

create function loyalloop_private.touch_updated_at()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  new.updated_at := pg_catalog.now();
  return new;
end;
$$;

create table public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '' check (char_length(full_name) <= 120),
  phone text check (phone is null or char_length(phone) <= 32),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.platform_admins (
  user_id uuid primary key references auth.users(id) on delete restrict,
  is_active boolean not null default true,
  granted_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.businesses (
  id uuid primary key default gen_random_uuid(),
  slug text not null check (slug = lower(slug) and slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and char_length(slug) <= 80),
  display_name text not null check (char_length(btrim(display_name)) between 1 and 120),
  category text check (category is null or char_length(category) <= 80),
  status public.business_status not null default 'pending',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint businesses_slug_key unique (slug)
);

-- Contact and approval metadata are separated so public business reads cannot
-- expose them, including to authenticated users who are not business members.
create table public.business_details (
  business_id uuid primary key references public.businesses(id) on delete cascade,
  contact_email text check (contact_email is null or char_length(contact_email) <= 254),
  contact_phone text check (contact_phone is null or char_length(contact_phone) <= 32),
  approval_status public.business_approval_status not null default 'pending',
  created_by uuid references auth.users(id) on delete set null,
  approved_by uuid references auth.users(id) on delete set null,
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint business_details_approval_fields_check check (
    (approval_status = 'approved' and approved_at is not null and approved_by is not null)
    or (approval_status <> 'approved' and approved_at is null and approved_by is null)
  )
);

create table public.business_branding (
  business_id uuid primary key references public.businesses(id) on delete cascade,
  logo_path text check (logo_path is null or (
    logo_path ~ ('^' || business_id::text || '/[^/].*$')
    and logo_path !~ '(^|/)\.\.(/|$)'
  )),
  background_color text not null default '#F8F6F0' check (background_color ~ '^#[0-9A-Fa-f]{6}$'),
  primary_color text not null default '#879780' check (primary_color ~ '^#[0-9A-Fa-f]{6}$'),
  secondary_color text not null default '#EDE6D7' check (secondary_color ~ '^#[0-9A-Fa-f]{6}$'),
  text_color text not null default '#292D28' check (text_color ~ '^#[0-9A-Fa-f]{6}$'),
  theme_name text not null default 'Sage & Cream' check (char_length(theme_name) <= 60),
  welcome_message text check (welcome_message is null or char_length(welcome_message) <= 160),
  description text check (description is null or char_length(description) <= 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.business_memberships (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete restrict,
  role public.business_member_role not null,
  status public.membership_status not null default 'active',
  can_enroll_customers boolean not null default false,
  can_award_stamps boolean not null default false,
  can_redeem_rewards boolean not null default false,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint business_memberships_business_user_key unique (business_id, user_id),
  constraint business_memberships_business_id_id_key unique (business_id, id),
  constraint business_memberships_owner_permissions_check check (
    role <> 'owner' or (can_enroll_customers and can_award_stamps and can_redeem_rewards)
  )
);

create table public.customer_profiles (
  user_id uuid primary key references public.profiles(user_id) on delete cascade,
  phone_verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.loyalty_programs (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null unique references public.businesses(id) on delete cascade,
  name text not null default 'Loyalty programme' check (char_length(btrim(name)) between 1 and 120),
  status public.program_status not null default 'draft',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint loyalty_programs_business_id_id_key unique (business_id, id)
);

create table public.reward_rules (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  program_id uuid not null,
  version integer not null check (version > 0),
  stamps_required integer not null check (stamps_required between 1 and 1000),
  reward_name text not null check (char_length(btrim(reward_name)) between 1 and 120),
  description text check (description is null or char_length(description) <= 500),
  reward_type text not null default 'free_item' check (reward_type in ('free_item', 'discount', 'other')),
  discount_percent integer check (discount_percent is null or discount_percent between 1 and 100),
  is_active boolean not null default false,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint reward_rules_program_version_key unique (program_id, version),
  constraint reward_rules_business_id_id_key unique (business_id, id),
  constraint reward_rules_business_program_fk foreign key (business_id, program_id)
    references public.loyalty_programs(business_id, id) on delete cascade,
  constraint reward_rules_discount_check check (
    (reward_type = 'discount' and discount_percent is not null)
    or (reward_type <> 'discount' and discount_percent is null)
  )
);

create unique index reward_rules_one_active_per_program_idx
  on public.reward_rules (program_id) where is_active;

create table public.customer_loyalty_memberships (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  customer_user_id uuid not null references public.customer_profiles(user_id) on delete restrict,
  program_id uuid not null,
  status public.membership_status not null default 'active',
  enrollment_idempotency_key text not null check (char_length(enrollment_idempotency_key) between 1 and 160),
  enrolled_by uuid references auth.users(id) on delete set null,
  enrolled_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint customer_loyalty_memberships_business_customer_key unique (business_id, customer_user_id),
  constraint customer_loyalty_memberships_enrollment_key unique (business_id, enrollment_idempotency_key),
  constraint customer_loyalty_memberships_business_id_id_key unique (business_id, id),
  constraint customer_loyalty_memberships_business_program_fk foreign key (business_id, program_id)
    references public.loyalty_programs(business_id, id) on delete restrict
);

create table public.reward_redemptions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  loyalty_membership_id uuid not null,
  reward_rule_id uuid not null,
  reward_name_snapshot text not null check (char_length(reward_name_snapshot) between 1 and 120),
  stamps_redeemed integer not null check (stamps_redeemed > 0),
  redeemed_by uuid references auth.users(id) on delete set null,
  idempotency_key text not null check (char_length(idempotency_key) between 1 and 160),
  redeemed_at timestamptz not null default now(),
  constraint reward_redemptions_business_id_id_key unique (business_id, id),
  constraint reward_redemptions_idempotency_key unique (business_id, idempotency_key),
  constraint reward_redemptions_membership_fk foreign key (business_id, loyalty_membership_id)
    references public.customer_loyalty_memberships(business_id, id) on delete restrict,
  constraint reward_redemptions_rule_fk foreign key (business_id, reward_rule_id)
    references public.reward_rules(business_id, id) on delete restrict
);

create table public.stamp_transactions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  loyalty_membership_id uuid not null,
  transaction_type public.stamp_transaction_type not null,
  stamp_delta integer not null check (stamp_delta <> 0),
  reward_redemption_id uuid,
  rule_version integer,
  reference text check (reference is null or char_length(reference) <= 160),
  performed_by uuid references auth.users(id) on delete set null,
  idempotency_key text not null check (char_length(idempotency_key) between 1 and 160),
  created_at timestamptz not null default now(),
  constraint stamp_transactions_direction_check check (
    (transaction_type = 'award' and stamp_delta > 0 and reward_redemption_id is null)
    or (transaction_type = 'redemption' and stamp_delta < 0 and reward_redemption_id is not null)
  ),
  constraint stamp_transactions_business_id_id_key unique (business_id, id),
  constraint stamp_transactions_idempotency_key unique (business_id, idempotency_key),
  constraint stamp_transactions_one_redemption_ledger_entry_key unique (business_id, reward_redemption_id),
  constraint stamp_transactions_membership_fk foreign key (business_id, loyalty_membership_id)
    references public.customer_loyalty_memberships(business_id, id) on delete restrict,
  constraint stamp_transactions_redemption_fk foreign key (business_id, reward_redemption_id)
    references public.reward_redemptions(business_id, id) on delete restrict
);

create table public.business_offers (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  title text not null check (char_length(btrim(title)) between 1 and 120),
  description text check (description is null or char_length(description) <= 1000),
  offer_type text not null check (char_length(offer_type) between 1 and 60),
  value text check (value is null or char_length(value) <= 120),
  terms text check (terms is null or char_length(terms) <= 1000),
  status public.offer_status not null default 'draft',
  is_public boolean not null default false,
  starts_at timestamptz,
  ends_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint business_offers_dates_check check (ends_at is null or starts_at is null or ends_at > starts_at),
  constraint business_offers_business_id_id_key unique (business_id, id)
);

create table public.business_subscriptions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  provider text not null check (char_length(provider) between 1 and 40),
  provider_subscription_id text,
  plan_code text not null check (char_length(plan_code) between 1 and 80),
  status public.subscription_status not null,
  current_period_start timestamptz,
  current_period_end timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint business_subscriptions_provider_id_key unique (provider, provider_subscription_id),
  constraint business_subscriptions_dates_check check (
    current_period_end is null or current_period_start is null or current_period_end > current_period_start
  ),
  constraint business_subscriptions_business_id_id_key unique (business_id, id)
);

create table public.audit_logs (
  id bigint generated always as identity primary key,
  business_id uuid references public.businesses(id) on delete restrict,
  actor_user_id uuid references auth.users(id) on delete set null,
  action text not null check (char_length(action) between 1 and 120),
  target_type text check (target_type is null or char_length(target_type) <= 80),
  target_id text check (target_id is null or char_length(target_id) <= 160),
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  request_id text check (request_id is null or char_length(request_id) <= 160),
  created_at timestamptz not null default now()
);

create index businesses_status_idx on public.businesses (status);
create index business_memberships_user_status_idx on public.business_memberships (user_id, status);
create index business_memberships_business_status_role_idx on public.business_memberships (business_id, status, role);
create index reward_rules_program_active_idx on public.reward_rules (program_id, is_active, version desc);
create index customer_loyalty_memberships_customer_idx on public.customer_loyalty_memberships (customer_user_id, status);
create index customer_loyalty_memberships_business_status_idx on public.customer_loyalty_memberships (business_id, status);
create index stamp_transactions_membership_created_idx on public.stamp_transactions (business_id, loyalty_membership_id, created_at desc);
create index reward_redemptions_membership_redeemed_idx on public.reward_redemptions (business_id, loyalty_membership_id, redeemed_at desc);
create index business_offers_public_active_idx on public.business_offers (business_id, starts_at, ends_at) where is_public and status = 'active';
create index business_subscriptions_business_status_idx on public.business_subscriptions (business_id, status);
create index audit_logs_business_created_idx on public.audit_logs (business_id, created_at desc);
create index audit_logs_actor_created_idx on public.audit_logs (actor_user_id, created_at desc);


