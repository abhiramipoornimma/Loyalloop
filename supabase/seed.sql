-- LoyalLoop seed data for local development.
-- Run against a fresh local Supabase project (supabase db reset).
-- Auth users must be created separately via signup or the Supabase dashboard;
-- this seed only provisions public business/reference data.

-- 1. Businesses
insert into public.businesses (slug, display_name, category, status) values
  ('willow-and-pine', 'Willow & Pine', 'Café & Dining', 'active'),
  ('amber-grain', 'Amber Grain Bakery', 'Food & Dining', 'active'),
  ('silver-shears', 'Silver Shears', 'Beauty', 'active'),
  ('still-water', 'Still Water Studio', 'Wellness', 'paused')
on conflict (slug) do nothing;

-- 2. Business details
insert into public.business_details (business_id, contact_email, contact_phone, approval_status, approved_at, approved_by)
select b.id, 'hello@willowandpine.example', '555-0101', 'approved', now(), null
from public.businesses b where b.slug = 'willow-and-pine'
on conflict (business_id) do nothing;

insert into public.business_details (business_id, contact_email, contact_phone, approval_status, approved_at, approved_by)
select b.id, 'bakes@ambergrain.example', '555-0102', 'approved', now(), null
from public.businesses b where b.slug = 'amber-grain'
on conflict (business_id) do nothing;

insert into public.business_details (business_id, contact_email, contact_phone, approval_status)
select b.id, 'snip@silvershears.example', '555-0103', 'approved', now()
from public.businesses b where b.slug = 'silver-shears'
on conflict (business_id) do nothing;

-- 3. Business branding
insert into public.business_branding (business_id, theme_name, welcome_message, description)
select b.id, 'Sage & Cream', 'Every visit brings you closer.', 'Neighbourhood café with seasonal drinks and baked goods.'
from public.businesses b where b.slug = 'willow-and-pine'
on conflict (business_id) do nothing;

insert into public.business_branding (business_id, theme_name, welcome_message, description)
select b.id, 'Warm Earth', 'Fresh bread, baked daily.', 'Artisan bakery using heritage grains.'
from public.businesses b where b.slug = 'amber-grain'
on conflict (business_id) do nothing;

-- 4. Loyalty programs
insert into public.loyalty_programs (business_id, name, status)
select b.id, 'Willow & Pine Rewards', 'active'
from public.businesses b where b.slug = 'willow-and-pine'
on conflict (business_id) do nothing;

insert into public.loyalty_programs (business_id, name, status)
select b.id, 'Amber Grain Stamps', 'active'
from public.businesses b where b.slug = 'amber-grain'
on conflict (business_id) do nothing;

-- 5. Reward rules
insert into public.reward_rules (business_id, program_id, version, stamps_required, reward_name, description, reward_type, is_active, minimum_purchase, validity_days)
select b.id, lp.id, 1, 6, 'Free coffee', 'Collect 6 stamps to enjoy a free coffee on us.', 'free_item', true, null, null
from public.businesses b
join public.loyalty_programs lp on lp.business_id = b.id
where b.slug = 'willow-and-pine' and lp.name = 'Willow & Pine Rewards'
on conflict (business_id, id) do nothing;

insert into public.reward_rules (business_id, program_id, version, stamps_required, reward_name, description, reward_type, is_active, minimum_purchase, validity_days)
select b.id, lp.id, 1, 8, 'Free loaf', 'Collect 8 stamps to receive a free sourdough loaf.', 'free_item', true, null, null
from public.businesses b
join public.loyalty_programs lp on lp.business_id = b.id
where b.slug = 'amber-grain' and lp.name = 'Amber Grain Stamps'
on conflict (business_id, id) do nothing;

-- 6. Business offers
insert into public.business_offers (business_id, title, description, offer_type, value, terms, status, is_public, starts_at, ends_at)
select b.id, 'First visit free', 'Your first coffee is on the house.', 'free_item', 'Free coffee', 'One per customer. Valid on first visit only.', 'active', true, now(), now() + interval '30 days'
from public.businesses b where b.slug = 'willow-and-pine'
on conflict (business_id, id) do nothing;

insert into public.business_offers (business_id, title, description, offer_type, value, terms, status, is_public, starts_at, ends_at)
select b.id, 'Weekend pastry deal', '15% off all pastries Saturday and Sunday.', 'discount', '15%', 'Valid Saturday–Sunday only. Not combinable with other offers.', 'active', true, now(), now() + interval '14 days'
from public.businesses b where b.slug = 'amber-grain'
on conflict (business_id, id) do nothing;

-- Note: platform_admins, business_memberships, customer_profiles, and
-- customer_loyalty_memberships require auth.users rows. Create those accounts
-- via the signup page or Supabase Auth, then link memberships through the
-- admin/owner workflows.
