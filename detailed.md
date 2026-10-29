# LoyalLoop Backend and Database Guide

This document is a code-based reference for AI assistants and developers working on the LoyalLoop backend. It describes the schema and the latest behavior represented by the checked-in migrations; it does **not** prove that those migrations have been applied to any hosted Supabase project.

## 1. Backend overview

- **Backend platform:** Supabase Auth, PostgreSQL, PostgREST/Data API, Storage, and an Edge Function.
- **Database schema:** application data is in `public`. Authorization helpers are in the non-API `loyalloop_private` schema. Supabase-managed identities live in `auth.users`.
- **Frontend client:** `supabase.js` creates the browser client from `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY`. The browser must use the anon/publishable key, never a service-role key.
- **Authorization model:** database grants restrict which operations/columns a client can attempt; row-level security (RLS) restricts which rows are visible or mutable; privileged `SECURITY DEFINER` RPCs perform multi-step writes after checking the caller.
- **Tenant key:** `business_id` scopes business-owned records. A staff or owner membership does not grant access to another business.
- **Billing:** subscription tables/status types exist as schema scaffolding. There is no billing provider workflow. Business onboarding intentionally creates no subscription.
- **Migration source of truth:** apply every SQL migration in filename order. Later migrations replace earlier workflow definitions. Do not treat an older migration's behavior as current when a later migration replaces it.

## 2. Migration sequence and current behavior

Apply these files in order:

1. `supabase/migrations/20261025120000_core_schema.sql` — enums, core tables, constraints, and indexes.
2. `supabase/migrations/20261025121000_identity_helpers_triggers.sql` — Auth profile provisioning, authorization helpers, updated-at and audit triggers.
3. `supabase/migrations/20261025122000_rls_grants_storage.sql` — RLS, SQL grants, and private business-logo bucket policies.
4. `supabase/migrations/20261025123000_authorized_workflows.sql` — admin, reward, enrollment, stamp-award, and redemption RPCs.
5. `supabase/migrations/20261026100000_business_applications.sql` — application table and initial submission/review flow.
6. `supabase/migrations/20261026120000_direct_admin_business_workflow.sql` — initial direct business-plus-owner RPC (later replaced).
7. `supabase/migrations/20261026130000_owner_admin_workflows.sql` — owner workflows, terms for rewards, staff invitation RPC, and application workflow update (later replaced in part).
8. `supabase/migrations/20261027100000_reviewed_application_workflow.sql` — **latest** application/review and create-from-application behavior.

The latest application flow is two steps: a platform admin reviews an application, then separately creates the business. Review verifies that a confirmed Auth account has the same email and records that user as the eligible owner; it does not create the business or membership. Business creation consumes a matching reviewed (or legacy approved) application and provisions the business and owner atomically. This is the behavior in the latest migration, regardless of earlier migration comments that describe an older flow.

> **Important migration inconsistency to resolve:** `20261027100000_reviewed_application_workflow.sql` adds a check constraint requiring `approved_owner_user_id IS NULL` when `status = 'reviewed'`, but its `review_business_application` function sets `approved_owner_user_id` to the matched Auth user while setting `status = 'reviewed'`. PostgreSQL will reject that review update with a check-constraint violation. The create-business RPC also searches for a reviewed row with a non-null `approved_owner_user_id`, confirming the intended state is to retain that ID. Verify the deployed migration and fix the constraint in a new forward migration before relying on the reviewed-then-created workflow. This guide describes intended data flow where noted, not proof that the current SQL executes successfully.

## 3. Entity and relationship map

```text
auth.users
  └── profiles ── customer_profiles
        ├── platform_admins
        ├── business_memberships ── businesses
        └── customer_loyalty_memberships ── businesses + loyalty_programs
                                         ├── stamp_transactions
                                         └── reward_redemptions ── reward_rules

businesses
  ├── business_details
  ├── business_branding
  ├── business_memberships
  ├── loyalty_programs ── reward_rules
  ├── business_offers
  ├── business_subscriptions (schema only; no provider workflow)
  ├── audit_logs
  └── business_applications (optional link once provisioned)
```

`business_id` is deliberately repeated in loyalty ledger and redemption tables. Composite foreign keys enforce that related memberships, programs, rules, and ledger rows belong to the same business.

## 4. Tables and important columns

All timestamps are `timestamptz` unless noted. UUID identifiers generally default to `gen_random_uuid()`. Unless otherwise stated, creation/update timestamps default to the database current time.

### Identity and roles

| Table | Purpose and important columns |
|---|---|
| `auth.users` | Supabase Auth-owned user records. Not an application table and must not be written directly by browser code. The configured project allows email signup without a confirmation step; onboarding workflows use the email on the Auth account. |
| `public.profiles` | One row per Auth user (`user_id` PK/FK); `full_name`, `phone`, `created_at`, `updated_at`. User-editable profile fields are limited by column grants and RLS. |
| `public.customer_profiles` | Customer capability/profile extension (`user_id` PK/FK to `profiles`, `phone_verified_at`, timestamps). Created for Auth users automatically. `phone_verified_at` is provider-controlled, not client-editable. |
| `public.platform_admins` | Trusted platform-admin allowlist (`user_id` PK/FK, `is_active`, `granted_by`, timestamps). Must be provisioned by a trusted administrator; no client insert policy/grant exists. |
| `public.business_memberships` | Business role and staff capabilities: `id`, `business_id`, `user_id`, `role` (`owner`/`staff`), `status` (`active`/`inactive`), `can_enroll_customers`, `can_award_stamps`, `can_redeem_rewards`, `created_by`, timestamps. Unique per business/user. Owner rows must have all three capabilities true. |

### Business setup and loyalty configuration

| Table | Purpose and important columns |
|---|---|
| `public.businesses` | Tenant root: `id`, unique lowercase hyphenated `slug`, `display_name`, `category`, `status` (`pending`, `active`, `paused`, `closed`), timestamps. Public callers receive only explicitly granted public columns. |
| `public.business_details` | Private contact and approval fields: `business_id` PK/FK, `contact_email`, `contact_phone`, `approval_status` (`pending`, `approved`, `rejected`), `created_by`, `approved_by`, `approved_at`, timestamps. Approval status and approval metadata must agree. |
| `public.business_branding` | One row per business: `logo_path`, background/primary/secondary/text hex colors, `theme_name`, `welcome_message`, `description`, timestamps. Logo path must begin with the owning business UUID folder. |
| `public.loyalty_programs` | One per business: `id`, `business_id`, `name`, `status` (`draft`, `active`, `paused`), timestamps. Composite `(business_id,id)` key supports same-business foreign keys. |
| `public.reward_rules` | Versioned reward terms: `id`, `business_id`, `program_id`, `version`, `stamps_required`, `reward_name`, `description`, `reward_type` (`free_item`, `discount`, `other`), optional `discount_percent`, `is_active`, `created_by`, `created_at`; later migration adds `minimum_purchase`, `validity_days`, `valid_until`. Unique version per program and at most one active rule per program. Discount rules require a 1–100 percent; other reward types must have no discount percent. |
| `public.business_offers` | Optional business marketing offers: `id`, `business_id`, `title`, `description`, `offer_type`, `value`, `terms`, `status` (`draft`, `active`, `paused`, `archived`), `is_public`, `starts_at`, `ends_at`, `created_by`, timestamps. End must be after start when both set. |

### Customer activity and ledger

| Table | Purpose and important columns |
|---|---|
| `public.customer_loyalty_memberships` | Customer enrollment per business/program: `id`, `business_id`, `customer_user_id`, `program_id`, `status`, `enrollment_idempotency_key`, `enrolled_by`, `enrolled_at`, `updated_at`. Unique `(business_id, customer_user_id)` and `(business_id, enrollment_idempotency_key)`. |
| `public.stamp_transactions` | Append-oriented stamp ledger: `id`, `business_id`, `loyalty_membership_id`, `transaction_type` (`award`/`redemption`), non-zero `stamp_delta`, optional `reward_redemption_id`, `rule_version`, `reference`, `performed_by`, `idempotency_key`, `created_at`. Awards have positive delta/no redemption; redemption transactions have negative delta/a redemption. Unique business/idempotency key and one ledger row per redemption. Clients have read access only; RPCs write. |
| `public.reward_redemptions` | Redemption record/snapshot: `id`, `business_id`, `loyalty_membership_id`, `reward_rule_id`, `reward_name_snapshot`, positive `stamps_redeemed`, `redeemed_by`, `idempotency_key`, `redeemed_at`. Same-business composite FKs and unique business/idempotency key. Clients have read access only; RPCs write. |

### Administration, billing scaffold, and applications

| Table | Purpose and important columns |
|---|---|
| `public.business_subscriptions` | Billing-provider scaffold: `id`, `business_id`, `provider`, optional `provider_subscription_id`, `plan_code`, `status` (`trialing`, `active`, `past_due`, `paused`, `cancelled`, `expired`), current period dates, timestamps. No checkout/provider integration or onboarding subscription creation is implemented. |
| `public.audit_logs` | Audit history: identity `id`, optional `business_id`/`actor_user_id`, `action`, optional target type/id, object-valued `metadata`, optional `request_id`, `created_at`. Client roles have read-only access filtered by policy; inserts are performed by trusted workflows/triggers. |
| `public.business_applications` | Applicant-submitted request: `id`, `business_name`, `owner_full_name`, `business_email`, `contact_phone`, `category`, optional `description`, `status`, `submitted_at`, `reviewed_at`, `reviewed_by`, optional `business_id`, and later-added `approved_owner_user_id`. Latest statuses are `pending`, `reviewed`, `approved`, `rejected`. Pending requests are unique by lowercased email; submission has a 24-hour repeat cooldown. Only active platform admins can read rows directly. Public submissions use an RPC. |

The `public` schema contains 16 application tables: 15 core tables from the first migration plus `business_applications`. `auth.users` and `storage.objects` are Supabase-managed.

## 5. Enums

- `business_status`: `pending`, `active`, `paused`, `closed`
- `business_approval_status`: `pending`, `approved`, `rejected`
- `business_member_role`: `owner`, `staff`
- `membership_status`: `active`, `inactive`
- `program_status`: `draft`, `active`, `paused`
- `offer_status`: `draft`, `active`, `paused`, `archived`
- `subscription_status`: `trialing`, `active`, `past_due`, `paused`, `cancelled`, `expired`
- `stamp_transaction_type`: `award`, `redemption`

Application status is `text` constrained by checks, not a PostgreSQL enum.

## 6. RLS policy catalog

RLS is enabled for all application tables. The migration does not enable `FORCE ROW LEVEL SECURITY`; security-definer workflows use explicit role checks and `row_security = off`. SQL grants still apply alongside RLS. A permissive policy is not enough if the role lacks the required table/column grant.

### Identity and business policies

| Table | Policy (migration name) | Effective rule |
|---|---|---|
| `profiles` | `profiles_select_self` | Authenticated user can select own profile. |
| `profiles` | `profiles_update_self` | Authenticated user can update own row; column grants permit only `full_name`, `phone`. |
| `platform_admins` | `platform_admins_select_admin` | Active platform admins can read the admin list. No client insert/update/delete policy. |
| `businesses` | `businesses_public_read` | Anonymous/authenticated callers can read only public businesses (active + approved details). |
| `businesses` | `businesses_member_read` | Active owner/staff of that business or platform admin can read. |
| `businesses` | `businesses_owner_update` | Active owner can update their business; grants limit columns to display name, slug, category. |
| `businesses` | `businesses_admin_read_all` | Platform admin can read all businesses. |
| `business_details` | `business_details_owner_admin_read` | Owner of that business or platform admin can read private detail row. |
| `business_details` | `business_details_owner_update_contact` | Owner can update row; grants limit columns to contact email/phone. |
| `business_branding` | `business_branding_public_read` | Public business branding is readable anonymously/authenticated. |
| `business_branding` | `business_branding_member_read` | Active owner/staff or platform admin can read branding. |
| `business_branding` | `business_branding_owner_insert` | Active owner can create branding row. |
| `business_branding` | `business_branding_owner_update` | Active owner can update branding row. |
| `business_memberships` | `business_memberships_read_self_owner_admin` | User can read own memberships; owner of business or platform admin can read business memberships. |
| `business_memberships` | `business_memberships_owner_add_staff` | Owner can insert only active staff memberships with self as creator. |
| `business_memberships` | `business_memberships_owner_update_staff` | Owner can update staff rows only; column grants restrict writable fields to status and capability flags. |
| `business_memberships` | `business_memberships_owner_delete_staff` | Owner can delete staff rows only. |
| `customer_profiles` | `customer_profiles_read_self_or_business` | User can read own row; a business with customer-data permission can read enrolled customers. No client write grant. |

### Loyalty and customer-data policies

| Table | Policy (migration name) | Effective rule |
|---|---|---|
| `loyalty_programs` | `loyalty_programs_public_read` | Anonymous/authenticated callers can read active programs for public businesses. |
| `loyalty_programs` | `loyalty_programs_member_read` | Owner/staff of business or platform admin can read programs. |
| `loyalty_programs` | `loyalty_programs_owner_insert` | Owner can insert only draft program. |
| `loyalty_programs` | `loyalty_programs_owner_update` | Owner can update program row; SQL column grants expose only name, and publishing/status changes use RPCs. |
| `loyalty_programs` | `loyalty_programs_admin_update` | Platform admin can update program row; SQL grants still apply. |
| `reward_rules` | `reward_rules_public_active_read` | Anonymous/authenticated callers can read active, unexpired reward rules for active programs/public businesses. Anonymous column grants are explicitly restricted. |
| `reward_rules` | `reward_rules_member_read` | Owner/staff of business or platform admin can read rules. |
| `customer_loyalty_memberships` | `customer_loyalty_memberships_read_customer_business` | Customer reads own enrollment; business with `view_customer_data` or platform admin can read. |
| `stamp_transactions` | `stamp_transactions_read_customer_business` | Enrolled customer reads own ledger; business with `view_customer_data` or platform admin can read. |
| `reward_redemptions` | `reward_redemptions_read_customer_business` | Enrolled customer reads own redemptions; business with `view_customer_data` or platform admin can read. |

### Offers, subscriptions, audit, and applications

| Table | Policy (migration name) | Effective rule |
|---|---|---|
| `business_offers` | `business_offers_public_read` | Anonymous/authenticated callers read only public active offers within their date window for public businesses. |
| `business_offers` | `business_offers_member_read` | Owner/staff of business or platform admin can read offers. |
| `business_offers` | `business_offers_owner_insert` | Owner can insert offers only with self as creator. |
| `business_offers` | `business_offers_owner_update` | Owner can update own business offers. |
| `business_offers` | `business_offers_owner_delete` | Owner can delete own business offers. |
| `business_subscriptions` | `business_subscriptions_owner_admin_read` | Business owner or platform admin can read subscription summary rows. No client write policy/grant. |
| `audit_logs` | `audit_logs_owner_admin_read` | Platform admin reads all; owner reads rows for their business. No client write policy/grant. |
| `business_applications` | `business_applications_admin_read` | Active platform admins can read application rows. No direct client write policy/grant. |

RLS policies combine with SQL grants from `20261025122000_rls_grants_storage.sql`. For example, a table policy may permit an update while the column grant still forbids changing protected columns. Browser clients must not bypass these controls.

## 7. Storage

The `business-logos` bucket is **private**, limited to 2 MiB per object, and accepts only `image/png`, `image/jpeg`, and `image/webp`.

Policies on `storage.objects`:

- `loyal_loop_public_business_logo_read`: anonymous/authenticated read only when the first folder segment is a valid business UUID and that business is active and approved. The frontend creates signed URLs for viewing private bucket objects.
- `loyal_loop_owner_business_logo_insert`: authenticated active business owner can upload only under their business UUID folder.
- `loyal_loop_owner_business_logo_update`: same owner/folder check for object updates.
- `loyal_loop_owner_business_logo_delete`: same owner/folder check for object deletion.

The bucket is for public-facing logos only, not private customer documents. Database `business_branding.logo_path` also validates the business UUID folder and rejects `..` path segments.

## 8. Authorization helpers and automatic triggers

Helpers are `SECURITY DEFINER`, use a fixed `pg_catalog` search path, and are not granted to `PUBLIC`/`anon`. Needed callers receive narrowly scoped execute grants.

- `loyalloop_private.is_platform_admin()` — true only when `auth.uid()` has an active `platform_admins` row.
- `loyalloop_private.has_business_role(business_id, role)` — true for the current authenticated user with an active membership matching that business and role.
- `loyalloop_private.has_business_permission(business_id, permission)` — owners have all permissions; staff permissions come from the three capability flags. `view_customer_data` for staff is true if any of their three capabilities is true.
- `loyalloop_private.is_public_business(business_id)` — business status is active and `business_details.approval_status` is approved.
- `loyalloop_private.can_view_customer_profile(user_id)` — user can see own profile; business staff/owner can see a customer profile only when their business permission allows customer data and the customer is enrolled in that business.

Triggers:

- `loyalloop_auth_user_profile_after_insert` provisions `profiles` and `customer_profiles` on new Auth user creation. It copies only `full_name` from signup metadata; it ignores role metadata. The migration also backfills existing Auth users.
- `*_touch_updated_at` triggers maintain `updated_at` on profiles, admins, businesses, business details/branding/memberships, customer profiles/memberships, programs, offers, and subscriptions.
- `*_audit_changes` triggers create audit rows for insert/update/delete on businesses, business details, platform admins, branding, business memberships, programs, offers, subscriptions. Audit metadata records changed field names, not old/new values.
- `reward_redemptions_valid_rule_before_insert` prevents redeeming an expired reward rule.
- `stamp_transactions_valid_rule_before_insert` prevents awarding stamps when the active reward rule has expired.

## 9. RPCs and write workflows

Database RPCs are the supported entry point for privileged or transactional writes. RPCs below are `SECURITY DEFINER` and perform their own authorization checks; do not infer authorization merely from the frontend hiding a button.

### Platform administration and onboarding

- `admin_create_business(p_slug, p_display_name, p_category, p_contact_email, p_contact_phone)` — platform admin only. Creates pending business and initial details, branding, and draft program rows. Internal building block.
- `admin_approve_business(p_business_id, p_owner_user_id)` — platform admin only. Marks details approved and business active, then creates/activates full-permission owner membership. Internal building block.
- `admin_set_business_status(p_business_id, p_status)` — platform admin only; only active/paused/closed are accepted, and activation requires approved details.
- `submit_business_application(p_business_name, p_owner_full_name, p_business_email, p_contact_phone, p_category, p_description)` — callable by anon/authenticated. Validates values, normalizes email, enforces 24-hour repeat-submission cooldown, records application and audit event. Does not grant owner access.
- `review_business_application(p_application_id, p_decision)` — active platform admin only. Reject records rejection; approve/review requires a confirmed Auth account with matching email. **Latest migration sets status to `reviewed` and records `approved_owner_user_id`; it does not create business/membership.** Legacy `approved` rows remain supported.
- `admin_create_business_with_owner(p_slug, p_display_name, p_category, p_contact_email)` — active platform admin only. Requires a reviewed/legacy-approved unconsumed application with matching email and still-confirmed eligible Auth user. Creates business, approves it, provisions owner, links application, and audits within one database transaction. Subscription is not created.

The business-application `status` state machine in current behavior:

```text
pending --admin review approve--> reviewed --admin creates business--> reviewed + business_id
pending --admin review reject--> rejected
```

`approved` is accepted as a legacy state for previously provisioned/unconsumed records. The latest create workflow finds either `reviewed` or `approved` with `business_id IS NULL`.

### Owner/staff configuration and rewards

- `owner_save_business_branding(p_business_id, p_display_name, p_logo_path, colors, theme, welcome, description)` — owner-only atomic save of display name/branding after validation; logo path is business-scoped.
- `publish_reward_rule(...)` — legacy reward publishing RPC from the core workflow.
- `publish_reward_rule_with_terms(...)` — current owner workflow for versioned reward rules, including minimum purchase, validity duration, and optional program activation. Enforces active approved business and reward constraints; deactivates previous rule and audits the new version.
- `set_loyalty_program_status(p_business_id, p_status)` — owner-only active/paused control; activation requires active approved business and a current active reward rule.
- `owner_add_invited_staff(p_business_id, p_owner_user_id, p_staff_user_id)` — `service_role` only. Verifies active owner and active approved business, creates a staff membership and audit row. Staff receive `can_enroll_customers=true`, `can_award_stamps=true`, and `can_redeem_rewards=true`.

### Customer enrollment and stamp ledger

- `search_business_customers(p_business_id, p_query)` — authenticated, permission-checked search of active customers for one business by name, email, phone, or account/membership ID. Returns only the matching customer identity fields needed by the staff dashboard.
- `enroll_customer(p_business_id, p_customer_user_id, p_idempotency_key)` — authenticated self-enrollment or authorized staff enrollment. Requires active approved business, active program, valid customer profile. One enrollment per business/customer; idempotency key reuse by another user fails.
- `award_stamp(p_loyalty_membership_id, p_stamp_count, p_idempotency_key, p_reference)` — active authorized owner/staff only. Exactly one stamp per call; requires active membership/business/program/rule; idempotent for same actor and same request; writes ledger plus audit. Direct client ledger writes are not granted.
- `redeem_reward(p_loyalty_membership_id, p_idempotency_key)` — active authorized owner/staff only. Locks membership, checks active business/program/rule and balance, inserts redemption plus negative stamp-ledger entry plus audit atomically. Idempotent for same actor/membership/request; prevents a balance going negative under concurrent redemption.

## 10. Edge Function: staff invitations

`supabase/functions/invite-business-staff/index.ts` is an authenticated POST endpoint:

1. Requires `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`; missing configuration returns 503.
2. Validates the bearer token by calling Auth `getUser`.
3. Validates input and confirms via service-role query that caller is an active owner of the business.
4. Checks for an existing Auth user by email. Existing accounts are added without a new invite; otherwise Auth sends an invitation email.
5. For a newly invited user, updates profile fields, then calls `owner_add_invited_staff` to atomically create membership/audit.

The service-role key belongs only in Edge Function secrets. Do not put it in `.env.local` variables exposed through the Vite `VITE_` prefix or in browser code. Partial failures after sending invitation are surfaced to the caller for administrator follow-up.

## 11. Client grants and write boundaries

The RLS/grants migration revokes broad table access first, then grants selected operations. Highlights:

- Public reads are column-limited for `businesses`, `reward_rules`, and `business_offers`. Private business contacts, Auth identity details, and admin metadata are not public.
- Authenticated users can read their own profiles and update only profile name/phone.
- No authenticated client direct write grants exist for `platform_admins`, customer profiles, customer loyalty memberships, stamp transactions, redemptions, or audit logs.
- Business owners have selected direct update grants for business details, branding, staff capability/status, program name, and offers, subject to RLS. Business creation, approval, role provisioning, reward publishing, status transitions, enrollment, award, and redemption use RPCs.
- Subscription rows can be read by business owners/platform admins, but no client writes are enabled and no provider provisions them.

## 12. Local development, seeds, and migrations

- `supabase/config.toml` sets local project id `Loyalloop`, Postgres major version 17, API schema exposure (`public`, `graphql_public`), and seed file `./seed.sql`.
- Local startup/reset documented in README: `supabase start`, then `supabase db reset`. Reset applies migrations and seed on a disposable local project.
- `supabase/seed.sql` inserts sample businesses, details, branding, programs, reward rules, and offers. It does **not** create Auth users, admins, owner/staff memberships, customer profiles, or customer enrollments. Create Auth users separately, then provision access through trusted workflows.
- Hosted projects: apply all migrations, in order, to the intended Supabase project. Then seed only if sample records are wanted. Confirm the Vite `.env.local` points to that same project.
- `supabase/tests/authorization_test_plan.sql` is a **manual validation plan**, not an executable test suite. Its JWT/API matrix should be run against disposable/staging infrastructure with distinct users and tokens. Catalog checks in SQL Editor do not prove actual PostgREST/Storage JWT behavior.

## 13. Debugging and AI change guidance

When a dashboard says data failed to load:

1. Check browser Network/Console for the exact failed table/RPC, HTTP status, and Postgres error.
2. Confirm `.env.local` points to the intended project and contains valid URL/anon key; restart Vite after changing environment values.
3. Confirm every migration—including the latest workflow migration—was applied to that project.
4. Check whether the session is valid and whether the user has an active membership for the correct business.
5. For a query error, inspect both the applicable SQL grant/column grant and RLS policy. A frontend generic message may hide the specific database error.

For AI coding agents:

- Read the latest relevant migrations before proposing schema or workflow changes.
- Add a **new forward-only migration** for deployed schema changes; do not edit an already-applied migration to alter production history.
- Maintain business scoping in joins, foreign keys, RPC validations, and RLS; never rely only on a client-supplied `business_id`.
- Keep privileged operations transactional, validate `auth.uid()`/role in SQL, use fixed `search_path`, and keep execute grants narrow.
- Do not add a subscription row or imply billing is active; a billing provider/state machine is not implemented.
- Keep secrets out of browser bundles. Only the Edge Function may receive the service-role secret.
- Treat the source as implementation evidence, not proof of deployed state. Verify Supabase migration history and deployed policies/functions before diagnosing a hosted environment.

## 14. Source files

- Schema: `supabase/migrations/20261025120000_core_schema.sql`
- Helpers and triggers: `supabase/migrations/20261025121000_identity_helpers_triggers.sql`
- RLS, grants, Storage: `supabase/migrations/20261025122000_rls_grants_storage.sql`
- Core RPCs: `supabase/migrations/20261025123000_authorized_workflows.sql`
- Application workflow history: `supabase/migrations/20261026100000_business_applications.sql`, `supabase/migrations/20261026130000_owner_admin_workflows.sql`, `supabase/migrations/20261027100000_reviewed_application_workflow.sql`
- Storage invitation endpoint: `supabase/functions/invite-business-staff/index.ts`
- Local configuration and seed: `supabase/config.toml`, `supabase/seed.sql`
- Authorization validation plan: `supabase/tests/authorization_test_plan.sql`
