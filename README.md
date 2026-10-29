# LoyalLoop

LoyalLoop is a customer-loyalty (stamp-card) platform with role-based dashboards for platform admins, business owners, staff, and customers. Frontend: vanilla JavaScript + Vite. Backend: Supabase (Auth, Postgres, Storage, Edge Functions).

## Project structure

```
.
├── app.js                  # Shared auth (login/register), password reset, dashboard routing
├── supabase.js             # Supabase client singleton (anon key only)
├── business-application.js # Business application dialog handler
├── styles.css              # Global styles
├── index.html              # Landing page
├── login.html              # Sign in (+ password reset dialog)
├── register.html           # Sign up
├── supabase-test.html      # Supabase connection test
├── vite.config.js          # Vite build + dev-server route rewrites
├── admin/                  # Platform admin dashboard
├── owner/                  # Business owner dashboard
├── staff/                  # Staff dashboard
├── customer/               # Customer dashboard + business loyalty card
├── b/                      # Public business loyalty pages
├── supabase/               # Migrations, seed, Edge Functions, config
│   ├── migrations/         # SQL migrations (schema, RLS, RPCs)
│   ├── seed.sql            # Local dev seed data
│   ├── functions/          # Edge Functions
│   └── config.toml         # Supabase CLI config
├── .env.example            # Environment variable template (copy to .env.local)
├── .env.local              # Local Supabase credentials (gitignored, never commit)
├── .gitignore              # Ignores .env.local, dist/, supabase/.temp/, node_modules
├── eslint.config.mjs       # ESLint flat config
├── .prettierrc             # Prettier formatting config
├── package.json            # Scripts: dev, build, lint, lint:fix, preview
└── README.md               # This file
```

## Setup

### 1. Install dependencies

```powershell
npm install
```

### 2. Configure Supabase

Copy the example env file and fill in your Supabase project credentials:

```powershell
copy .env.example .env.local
```

Edit `.env.local`:

```
VITE_SUPABASE_URL=https://your-project-ref.supabase.co
VITE_SUPABASE_ANON_KEY=your-supabase-anon-key
```

Find these values in your Supabase project Settings → API. Only the anon key is used in the browser; never put a `service_role` key in `.env.local`.

### 3. Apply database migrations

**Local development (Supabase CLI):**

```powershell
supabase start
supabase db reset
```

`seed.sql` provisions sample businesses, loyalty programs, reward rules, and offers. Auth users (admin, owner, staff, customers) must be created via the signup page or Supabase Auth dashboard, then linked through the admin/owner workflows.

**Hosted Supabase project:** Apply the migrations in `supabase/migrations/` in order through the Supabase SQL Editor, then run `seed.sql`.

### 4. Run the dev server

```powershell
npm run dev
```

Visit `http://localhost:5173` (or the port Vite reports).

### Other npm scripts

| Script | Purpose |
|--------|---------|
| `npm run dev` | Start Vite dev server with dashboard route rewrites |
| `npm run build` | Production build via Vite |
| `npm run preview` | Preview the production build locally |
| `npm run lint` | ESLint on source files |
| `npm run lint:fix` | ESLint with auto-fix |

## How it works

### Roles and dashboards

| Role | Path | Purpose |
|------|------|---------|
| Platform admin | `/admin/dashboard/` | Review business applications, manage businesses |
| Business owner | `/owner/dashboard/` | Branding, reward rules, staff, customers, redemptions |
| Staff | `/staff/dashboard/` | Search customers, add stamps, redeem rewards |
| Customer | `/customer/dashboard/` | View memberships, join programmes, loyalty cards |
| Public (no auth) | `/b/:slug` | Public business loyalty page |

### Authentication and routing

`supabase.js` creates a single Supabase client using `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY`. Every request carries the signed-in user's JWT. `app.js` handles sign-in, sign-up, password reset, and post-login routing:

- Platform admin → `/admin/dashboard/`
- Business owner → `/owner/dashboard/`
- Staff → `/staff/dashboard/`
- Customer (no business membership) → `/customer/dashboard/`
- No role → error message, contact an administrator

Signup creates a `profiles` row and `customer_profiles` row via a database trigger (`provision_auth_user_profile`) — signup metadata never carries roles or permissions.

### Key workflows

- **Business application**: An owner applies via the sign-in page ("Wanna add your business to LoyalLoop?"). The applicant must register and confirm a LoyalLoop account using the business email. A platform admin reviews and approves the application; LoyalLoop then creates the business, branding, loyalty program, and grants owner access to the matching account atomically.
- **Customer enrolment**: A signed-in customer joins a business's loyalty programme via the customer dashboard ("Join a Loyalty Programme") by entering the business slug.
- **Staff customer enrolment**: Staff with `can_enroll_customers` can enroll an existing LoyalLoop customer in their assigned business by email. The customer must already have an account; cross-business enrollment is rejected.
- **Staff invites**: Business owners invite staff via the staff management dialog. Requires the `invite-business-staff` Edge Function deployed with `SUPABASE_SERVICE_ROLE_KEY` and SMTP configured.
- **Stamps and redemptions**: Staff award one stamp per customer action via `award_stamp`; staff redeem rewards via `redeem_reward`. Both use idempotency keys so repeated requests are safe.
- **Password reset**: "Forgot password?" on the sign-in page sends a reset link via Supabase Auth.

## Key decisions

**Database-level authorization, not just UI-level:** Row Level Security (RLS) is enabled on all 15 public tables. The frontend never trusts the UI to hide data — every table read/write is gated by Postgres policies that check the caller's business membership.

**Security-definer RPCs for all privileged writes:** Direct client INSERT/UPDATE/DELETE on loyalty ledgers (`customer_loyalty_memberships`, `stamp_transactions`, `reward_redemptions`, `audit_logs`), `platform_admins`, and `customer_profiles` is revoked. All writes go through `security definer` functions (`enroll_customer`, `award_stamp`, `redeem_reward`, `publish_reward_rule`, `owner_save_business_settings`, etc.) that verify the caller's role before writing.

**Private helper schema:** Authorization helpers (`has_business_role`, `has_business_permission`, `is_platform_admin`, `is_public_business`, `can_view_customer_profile`) live in `loyalloop_private`, a schema revoked from `public`/`anon`/`authenticated` and only granted `EXECUTE` to specific roles via policies. Functions use `set row_security = off` internally but always re-check `auth.uid()` against `business_memberships`.

**No `service_role` in the browser:** The frontend client uses only the anon key + user JWT. The `service_role` key is used exclusively inside the `invite-business-staff` Edge Function (server-side Deno), never bundled into the frontend.

**Idempotency keys:** Enrollment, stamp awards, and redemptions require an idempotency key. Reusing a key for a different operation (different customer, different membership, different actor) raises an error instead of duplicating the write.

**Storage isolation:** Business logos are stored in a private `business-logos` bucket under UUID-named folders. Storage policies require `has_business_role(folder_business_id, 'owner')` for writes and `is_public_business(...)` for reads. Path traversal (`..`) and malformed UUID folders are rejected.

## Limitations

- **Subscriptions/billing is stubbed:** `business_subscriptions` table and RLS exist, but no billing provider workflow or payment integration is configured yet. The admin UI subscription section was removed pending a real provider.
- **Email confirmation is disabled** in local `config.toml` (`enable_confirmations = false`). For production, enable double opt-in if email verification matters for your deployment.
- **No re-enrollment after inactive status:** Once a customer membership is set to `inactive`, re-enrollment is intentionally unsupported and requires a future audited workflow.
- **No unique purchase/visit reference:** Idempotency keys prevent exact duplicate RPC calls, but distinct keys can still represent duplicate visits. A unique purchase/visit reference would be needed to close that gap.
- **Staff invites require SMTP + Edge Function deployment:** The `invite-business-staff` Edge Function must be deployed separately with `SUPABASE_SERVICE_ROLE_KEY` and SMTP configured; it is not part of the Vite build.
- **Authorization test plan is not executable:** `supabase/tests/authorization_test_plan.sql` is a validation matrix for manual review, not an automated test suite.
- **Local seed data only:** `seed.sql` is for local development. Auth users must be created separately through signup or the Auth dashboard.

## Security features

| Feature | Enforcement |
|---------|-------------|
| Row Level Security | Enabled on all 15 public tables |
| No direct client writes on ledgers | INSERT/UPDATE/DELETE revoked on `customer_loyalty_memberships`, `stamp_transactions`, `reward_redemptions`, `audit_logs`, `platform_admins`, `customer_profiles` |
| Business-scoped reads/writes | Policies gate on `has_business_role(business_id, ...)` / `has_business_permission(business_id, ...)` checked against `business_memberships` |
| Platform admin gating | Admin-only functions require `is_platform_admin()`, provisioned out-of-band (never self-service) |
| Private helper schema | `loyalloop_private` schema revoked from PUBLIC; helpers only executable via grant |
| Security-definer RPCs | All privileged workflows run as the function owner but re-check `auth.uid()` and business membership |
| Storage isolation | Logo bucket is private; writes require owner role on the matching business UUID folder; reads require public/approved business |
| Idempotency keys | Enrollment, stamp awards, and redemptions reject reused keys across different operations |
| No service_role in browser | Frontend uses anon key only; service_role confined to server-side Edge Function |
| Column-level grants | Public business reads expose only `id, slug, display_name, category, status`; contacts and approval metadata are not granted to `anon` |

## Cross-business isolation

Business A cannot see or change Business B's data through the screens, URL manipulation, or direct API calls:

- **Screens**: Owner/staff dashboards call owner-staff RPCs that check `has_business_role(business_id, 'owner')` / `has_business_permission(business_id, ...)` for the business in context. Business A's credentials never satisfy Business B's checks.
- **URL/ID substitution**: PostgREST applies the same RLS policies regardless of which row ID is in the URL. Without an active `business_memberships` row for Business B, all reads and writes on Business B's rows are denied.
- **Direct API calls**: Same RLS enforcement applies. Security-definer RPCs validate the caller's business membership before any write; direct table writes on ledgers are revoked entirely.

The only exception is platform administrators, who can read all businesses by design (provisioned out-of-band, never self-service).