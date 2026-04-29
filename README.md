# Libber

A loyalty points app. Customers join stores and accumulate points. Staff award points and manage redemptions. Managers approve staff. Admins manage stores and rules.

---

## Architecture

Two separate web apps built from one codebase, deployed to one Vercel project.

| App | Audience | Root |
|---|---|---|
| **Customer** | End users — join stores, view balances, earn and redeem points | `apps/customer/` |
| **Staff** | Staff, managers — award points, approve applicants, manage staff | `apps/staff/` |

**Admin tool** (`adminstart.html`) — local only, never deployed. Used to create stores, configure reward rules, and assign managers.

---

## Pages

### Customer (`apps/customer/`)

| File | Purpose |
|---|---|
| `index.html` | Home — user ID, joined store balances, join/unjoin stores, save-prompt button, points history per store |
| `save.html` | Save account — shown after identity linking via magic link or OAuth |
| `settings.html` | Settings — account options |

### Staff (`apps/staff/`)

| File | Purpose |
|---|---|
| `index.html` | Store picker — shows approved stores, apply for new ones |
| `page.html` | Staff tools — load members, award points |
| `manager.html` | Manager tools — approve/reject applicants, manage staff |

### Admin (local only)

`adminstart.html` — create stores, configure reward rules (with ordering), assign managers and staff. Your public ID is shown at the top for use with `assign-admin.sql`.

---

## Project Structure

```
apps/
  customer/
    index.html
    save.html
    settings.html
    manifest.json       PWA manifest
    sw.js               Service worker (cache versioned at build time)
  staff/
    index.html
    page.html
    manager.html
adminstart.html         Local admin tool (not deployed)
scripts/
  sql/                  All DB scripts (see SQL Scripts section)
src/
  lib/
    dom.js              $ (getElementById), $q (querySelector), $$ (querySelectorAll)
    escape.js           escapeHtml — used before any user value hits the DOM
    format.js           Shared formatting helpers
    sentry.js           Sentry init, setSentryUser(), captureError()
    storage.js          Shared localStorage helpers
    supabase.js         Supabase client (anon key)
    theme.js            Theme utilities
  pages/
    admin/start.js      Admin page controller (local only)
    customer/
      main.js           Customer home controller
      save.js           Save account controller
      settings.js       Settings controller
    manager/start.js    Manager page controller
    staff/
      start.js          Staff store picker controller
      page.js           Staff tools controller
  services/
    admin.js            Store, rule, and admin RPC calls
    applicants.js       apply_for_staff/manager, approve, reject, demote
    auth.js             Anonymous auth bootstrap, resetSession() (dev only)
    members.js          loadUserProfile, loadCustomerHome, loadMembers, loadPointsHistory
    staff.js            loadStaffStores (unions store_staff + store_managers)
    stores.js           getStores, joinStore, unjoinStore, getStoreBonusCap
  state/state.js        Shared in-memory state
  ui/
    renderCustomers.js  Staff member panel — award, bonus, adjust, redeem
    renderStores.js     Store join/unjoin cards
    renderUser.js       User ID header, joined-store cards, expandable history
    savePrompt.js       Save-prompt button — render(), glow()
    settingsCog.js      Settings cog UI
eslint.config.js
vite.config.js
vercel.json
```

---

## Stack

| Layer | Technology |
|---|---|
| Build | Vite 8 |
| Language | Vanilla JavaScript (ES modules, no framework) |
| Backend | Supabase — anon auth, RLS, SECURITY DEFINER RPCs |
| Error tracking | Sentry (`@sentry/browser`) — source maps uploaded at build, disabled in dev |
| Linting | ESLint 10 (flat config) |
| Git hooks | Husky — runs `npm run lint` on pre-commit |
| Deployment | Vercel — auto-deploys on push to `main` |

---

## Local Setup

**1. Install dependencies**

```bash
npm install
```

**2. Create `.env.local`**

```bash
VITE_SUPABASE_URL=your_supabase_project_url
VITE_SUPABASE_ANON_KEY=your_supabase_anon_key
SENTRY_AUTH_TOKEN=your_sentry_auth_token
```

`SENTRY_AUTH_TOKEN` is used by the Vite build plugin to upload source maps to Sentry. Get it from Sentry → Settings → Auth Tokens.

**3. Start dev server**

```bash
npm run dev
```

**4. Pages**

| Page | URL |
|---|---|
| Customer home | `http://localhost:5173/apps/customer/` |
| Staff store picker | `http://localhost:5173/apps/staff/` |
| Staff tools | `http://localhost:5173/apps/staff/page.html` |
| Manager tools | `http://localhost:5173/apps/staff/manager.html` |
| Admin (local) | `http://localhost:5173/adminstart.html` |

---

## Build

```bash
npm run build
```

Vite builds six page bundles defined in `vite.config.js`. Source maps are generated with `sourcemap: 'hidden'` — uploaded to Sentry at build time, never served publicly.

```
dist/
  apps/customer/index.html
  apps/customer/save.html
  apps/customer/settings.html
  apps/staff/index.html
  apps/staff/page.html
  apps/staff/manager.html
```

The admin tool is never built — run it locally in dev only.

---

## Deployment

Deployed on Vercel. Auto-deploys on push to `main`.

- Framework: Vite (auto-detected)
- Build command: `npm run build`
- Output directory: `dist`

**Live URLs**

| Page | URL |
|---|---|
| Customer home | `https://libber.vercel.app` |
| Staff store picker | `https://libber.vercel.app/apps/staff/` |
| Staff tools | `https://libber.vercel.app/apps/staff/page.html` |
| Manager tools | `https://libber.vercel.app/apps/staff/manager.html` |

**Environment variables** (Vercel → Settings → Environment Variables)

| Variable | Where to get it |
|---|---|
| `VITE_SUPABASE_URL` | Supabase Dashboard → Project Settings → API |
| `VITE_SUPABASE_ANON_KEY` | Supabase Dashboard → Project Settings → API |
| `SENTRY_AUTH_TOKEN` | Sentry → Settings → Auth Tokens |

`vercel.json` handles the root redirect (`/` → customer home), security headers (CSP, X-Frame-Options, etc.), and Supabase/Sentry connect-src allowlist.

---

## Auth

Anonymous Supabase auth (`src/services/auth.js`):

- Every visitor gets an anonymous Supabase session automatically — no signup required
- All role and permission checks are tied to `auth.uid()` inside RPCs and RLS policies
- A `create_profile` database trigger fires on every new auth user, creating a `profiles` row with a generated human-readable `public_id` (e.g. `MQH 335 484`) and a weighted-random A/B variant assignment
- If a stored JWT references a deleted user, `initAuth()` detects the error, signs out, and creates a fresh anonymous session
- After successful auth, `setSentryUser()` sets the Sentry user context to `auth.uid()` for error attribution

---

## Product Flow

### Customer

1. Open `apps/customer/` — anonymous session starts, profile created
2. Joined stores and balances load from cache instantly, then refresh from the server
3. A save-prompt button is shown once the user has earned any points (A/B tested text). It glows briefly when new points are detected
4. Tap a store card to expand: award rules, redeem options, last 10 transactions
5. Join or unjoin stores — points are preserved if the user rejoins later

### Staff

1. Open `apps/staff/` — approved stores listed under "Your stores"
2. Click a store → goes to `page.html` for that store
3. Load members, click a member to open their panel, award points via rule buttons or bonus section
4. "← My Stores" returns to the store picker

### Manager

1. Open `apps/staff/manager.html`
2. Your managed stores are listed — click one to load applicants and staff
3. Approve or reject applicants; remove staff members
4. Apply to manage additional stores from the bottom section

### Admin (local)

1. Run dev server, open `http://localhost:5173/adminstart.html`
2. Copy your public ID at the top, run `assign-admin.sql` to grant yourself admin access
3. Create stores, configure reward rules (label, points, kind, order)
4. Assign and remove managers and staff

---

## Points Model

Points are **not fungible across stores**. Each store's balance is independent.

---

## Reward Rules

Staff page buttons are driven by `store_reward_rules` in Supabase — not hardcoded. Configured per store in the admin tool.

| Kind | Purpose |
|---|---|
| `award` | Quick-award buttons — label + points |
| `redeem` | Redemption buttons — label + point cost |
| `bonus_reason` | Bonus reason options — label only |
| `bonus_amount` | Bonus amount buttons — point value only |

Staff must pick one bonus reason and one bonus amount to unlock the bonus award. The per-store bonus cap (`max_bonus_points`) limits visible bonus amount buttons. Quick-award buttons bypass the cap.

---

## Transaction History

Each store card shows the last 10 transactions, colour-coded by type. Type is inferred at render time — no extra DB column.

| Type | Colour | How identified |
|---|---|---|
| Award | Green | Points > 0, reason matches an `award` rule label |
| Redeem | Purple | Points < 0 |
| Bonus | Amber | Points > 0, reason matches a `bonus_reason` label |
| Adjust | Blue | Everything else |

---

## A/B Testing

The `ab_variants` table drives configurable experiments. The save prompt is the first experiment (`test_name = 'save_prompt'`).

- Each row: `test_name`, `variant`, `text`, `position`, `weight`, `is_active`
- Variant assigned once at profile creation using Efraimidis-Spirakis weighted reservoir sampling
- `load_customer_home` reads the variant's current text and position on every call — text changes take effect immediately without reassigning variants
- If a variant is deactivated or deleted, `load_customer_home` returns `save_prompt: null` and the client hides the prompt

**Current save_prompt variants**

| Variant | Text | Weight |
|---|---|---|
| A | Save your points | 50 |
| B | Don't lose your points | 50 |

---

## Save Prompt

A persistent button on the customer home page that encourages users to save their account.

- Only shown once the user has at least one point at any store
- Hidden permanently once `account_linked_at` is set on the profile
- Text and position come from the assigned `ab_variants` row — configurable without a deploy
- Glows briefly when new points are detected (balance increased since last cache). Suppressed on first load

---

## Supabase Tables

| Table | Purpose |
|---|---|
| `profiles` | Human-readable public ID, A/B variant assignment, account link tracking |
| `stores` | Store records |
| `store_memberships` | Which users are members of which stores |
| `store_staff` | Approved staff per store |
| `store_managers` | Approved managers per store |
| `store_staff_applicants` | Pending staff applications |
| `store_manager_applicants` | Pending manager applications |
| `points_ledger` | Every points transaction. On `supabase_realtime` publication |
| `store_reward_rules` | Award and redeem rules per store |
| `ab_variants` | A/B test variant definitions |
| `admins` | Users with admin access |

---

## Supabase RPCs

All write operations go through RPCs. No direct client writes.

| RPC | Auth check | What it does |
|---|---|---|
| `join_store` | `auth.uid()` | Creates store membership (ON CONFLICT DO NOTHING) |
| `unjoin_store` | `auth.uid()` | Removes caller's membership |
| `apply_for_staff` | `auth.uid()` | Creates staff applicant record |
| `apply_for_manager` | `auth.uid()` | Creates manager applicant record |
| `approve_staff_applicant` | Manager of store | Promotes applicant to staff, removes applicant record |
| `reject_staff_applicant` | Manager of store | Rejects and removes a staff applicant |
| `demote_store_staff` | Manager of store | Removes a user from store staff |
| `award_points` | Staff or manager of store | Inserts ledger entry, enforces bonus cap |
| `adjust_points` | Staff or manager of store | Inserts positive or negative correction, no cap |
| `load_customer_home` | `auth.uid()` | Returns profile, memberships, balances, rules, history, save prompt data in one call |
| `load_store_members` | Staff or manager of store | Returns members with balances and public IDs |
| `load_store_staff_profiles` | Manager of store | Returns staff with public IDs |
| `mark_account_linked` | `auth.uid()` | Sets `account_linked_at` on the caller's profile |
| `admin_create_store` | Admin | Creates a store |
| `admin_update_store` | Admin | Renames a store |
| `admin_remove_store` | Admin | Deletes a store and all related data |
| `admin_insert_reward_rule` | Admin | Adds a reward rule |
| `admin_delete_reward_rule` | Admin | Deletes a reward rule |
| `admin_update_reward_rule_order` | Admin | Updates rule sort order |
| `admin_set_bonus_cap` | Admin | Sets or clears the bonus cap for a store |
| `admin_assign_manager` | Admin | Assigns a user as manager |
| `admin_remove_manager` | Admin | Removes a manager |
| `admin_assign_staff` | Admin | Directly assigns a user as staff |
| `admin_remove_staff` | Admin | Removes a user from store staff |
| `admin_approve_applicant` | Admin | Approves a staff applicant |
| `admin_reject_applicant` | Admin | Rejects a staff applicant |
| `admin_reject_manager_applicant` | Admin | Rejects a manager applicant |
| `is_admin` | — | Helper: returns true if caller is in `admins` table |

**Views**

| View | Purpose |
|---|---|
| `admin_user_directory` | All users with public IDs |
| `staff_applicant_directory` | Applicants per store with public IDs |

**Trigger**

`create_profile` — fires on `auth.users` insert. Creates a `profiles` row with a generated `public_id` and weighted A/B variant assignment.

---

## Security

### Write path

All writes go through `SECURITY DEFINER` RPCs. RLS blocks direct client writes to every table.

```
Client → RPC (checks auth.uid() / is_admin()) → writes to table
Client → direct INSERT/UPDATE/DELETE → blocked by RLS
```

All SECURITY DEFINER RPCs use `SET search_path = ''` and fully qualified `public.table_name` references to prevent search path injection.

### Write access by table

| Table | Blocked direct | Via RPC only |
|---|---|---|
| `stores` | ✓ | `admin_create_store`, `admin_update_store`, `admin_remove_store` |
| `store_reward_rules` | ✓ | `admin_insert_reward_rule`, `admin_delete_reward_rule`, `admin_update_reward_rule_order` |
| `store_memberships` | ✓ | `join_store`, `unjoin_store` |
| `store_staff` | ✓ | `approve_staff_applicant`, `demote_store_staff`, `admin_assign_staff`, `admin_remove_staff` |
| `store_managers` | ✓ | `admin_assign_manager`, `admin_remove_manager` |
| `store_staff_applicants` | ✓ | `apply_for_staff`, `approve_staff_applicant`, `reject_staff_applicant`, `admin_approve_applicant`, `admin_reject_applicant` |
| `store_manager_applicants` | ✓ | `apply_for_manager`, `admin_assign_manager`, `admin_reject_manager_applicant` |
| `points_ledger` | ✓ | `award_points`, `adjust_points` |
| `ab_variants` | ✓ | Supabase dashboard only |

### SELECT RLS policies

| Table | Policy |
|---|---|
| `profiles` | Own row only — `auth.uid() = user_id` |
| `stores` | Public — `USING (true)` |
| `store_reward_rules` | Public — `USING (true)` |
| `ab_variants` | Public — `USING (true)` |
| `store_memberships` | Own rows — `user_id = auth.uid()` |
| `points_ledger` | Own rows + staff/manager of the store |
| `store_staff` | Self, manager-of-store, or admin |
| `store_staff_applicants` | Manager-of-store, applicant-self, or admin |
| `store_managers` | `user_id = auth.uid()` or admin |
| `store_manager_applicants` | `user_id = auth.uid()` or admin |
| `admins` | Service role only — `is_admin()` reads via SECURITY DEFINER |

### Function grants

All public RPCs are callable by `authenticated` only. `anon` and `PUBLIC` have `EXECUTE` revoked on all public functions. Re-run `fix-default-privileges.sql` after any migration that creates or replaces functions.

### XSS

All user-controlled values are escaped via `src/lib/escape.js` before being written to the DOM.

### Admin identity

Admin RPCs call `is_admin()` — a SECURITY DEFINER helper that checks `auth.uid()` against the `admins` table. Grant admin access by running `assign-admin.sql` with the target user's public ID.

---

## Observability

Sentry (`@sentry/browser`) is active in production only (`enabled: import.meta.env.PROD`).

- `captureError(err, { fn: 'name' })` is called on every RPC error path across all deployed pages
- Sentry user context is set to `auth.uid()` after auth completes (`setSentryUser`)
- Source maps are uploaded to Sentry at build time (`sourcemap: 'hidden'`) — not served publicly
- Alerts configured in Sentry for new issues

---

## Linting

ESLint 10 with flat config (`eslint.config.js`). Covers `src/**/*.js` and `scripts/**/*.mjs`.

```bash
npm run lint
```

Runs automatically on every commit via Husky pre-commit hook.

Rules: `no-unused-vars` (args prefixed `_` are exempt), `no-undef`, `no-empty` (empty catch blocks allowed), `no-console` off.

---

## SQL Scripts

All scripts in `scripts/sql/`. Paste into Supabase Dashboard → SQL Editor. All are safe to re-run.

| Script | What it does |
|---|---|
| `admin-rpcs.sql` | `admins` table, `is_admin()` helper, RESTRICTIVE RLS on `stores` and `store_reward_rules`, all admin RPCs |
| `staff-rpcs.sql` | RESTRICTIVE RLS on `store_memberships`, `store_staff`, `store_staff_applicants`, `points_ledger`. Staff and manager RPCs |
| `add-manager-applicants.sql` | `store_manager_applicants` table, `apply_for_manager`, `admin_assign_manager`, `admin_remove_store` |
| `add-bonus-cap.sql` | `max_bonus_points` on `stores`, `award_points` RPC with cap logic, `admin_set_bonus_cap` |
| `add-rls-select-policies.sql` | SELECT RLS policies for all client-read tables |
| `add-load-customer-home-rpc.sql` | `load_customer_home` RPC baseline (superseded by `add-ab-testing.sql`) |
| `add-load-store-members-rpc.sql` | `load_store_members` RPC |
| `add-reject-applicant-rpc.sql` | `reject_staff_applicant` RPC |
| `add-ab-testing.sql` | `ab_variants` table + RLS, new profile columns, weighted variant assignment trigger, updated `load_customer_home` |
| `add-bonus-adjust.sql` | Extends `store_reward_rules` kind check, adds `adjust_points` RPC |
| `add-save-account.sql` | `mark_account_linked` RPC |
| `add-load-store-staff-profiles-rpc.sql` | `load_store_staff_profiles` RPC |
| `rename-account-linked.sql` | Renames `email_saved_at` → `account_linked_at` and `mark_email_saved` → `mark_account_linked` throughout |
| `harden-rls-and-grants.sql` | Security hardening: scoped RLS on profiles/staff/applicants, anon grants revoked, function grants restricted to authenticated |
| `fix-default-privileges.sql` | Re-revokes anon/PUBLIC execute on all public functions and re-grants to authenticated. Re-run after any migration that creates or replaces functions |
| `assign-admin.sql` | Grants admin access by public ID |
| `delete-store.sql` | Deletes one store and all its data |
| `delete-user.sql` | Deletes one user by public ID |
| `delete-all-users.sql` | Deletes all users. Leaves stores and rules intact |
| `reset-all.sql` | Full wipe — every row including auth users. No undo |

---

## Fresh Setup

### New Supabase project — run scripts in this order

1. `admin-rpcs.sql`
2. `staff-rpcs.sql`
3. `add-manager-applicants.sql`
4. `add-bonus-cap.sql`
5. `add-rls-select-policies.sql`
6. `add-load-customer-home-rpc.sql`
7. `add-load-store-members-rpc.sql`
8. `add-reject-applicant-rpc.sql`
9. `add-ab-testing.sql`
10. `add-bonus-adjust.sql`
11. `add-save-account.sql`
12. `add-load-store-staff-profiles-rpc.sql`
13. `rename-account-linked.sql`
14. `harden-rls-and-grants.sql`
15. `fix-default-privileges.sql`
16. Open `adminstart.html` locally, copy your public ID, run `assign-admin.sql`
17. Reload admin tool — create stores, configure rules, assign managers

### After a full reset (`reset-all.sql`)

Schema (RPCs, RLS, triggers) survives a reset — it lives in the schema, not the data. Only re-run steps 16–17.

---

## DB Security Audit Queries

Run in Supabase Dashboard → SQL Editor to audit RLS and grant posture.

**1. RLS status per table**
```sql
SELECT
  c.relname                        AS table_name,
  c.relrowsecurity                 AS rls_enabled,
  c.relforcerowsecurity            AS rls_forced,
  COUNT(p.policyname)              AS policy_count,
  CASE
    WHEN NOT c.relrowsecurity                         THEN 'OPEN — no RLS'
    WHEN c.relrowsecurity AND COUNT(p.policyname) = 0 THEN 'BLOCKED — RLS on, no policies'
    ELSE 'ok'
  END                              AS status
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_policies p
       ON p.schemaname = n.nspname
      AND p.tablename  = c.relname
WHERE n.nspname = 'public'
  AND c.relkind  = 'r'
GROUP BY c.relname, c.relrowsecurity, c.relforcerowsecurity
ORDER BY status, table_name;
```

**2. All RLS policies**
```sql
SELECT tablename, policyname, roles, cmd,
       qual       AS using_expr,
       with_check AS check_expr
FROM pg_policies
WHERE schemaname = 'public'
ORDER BY tablename, cmd;
```

**3. Table grants to anon / authenticated**
```sql
SELECT table_name, grantee, privilege_type
FROM information_schema.role_table_grants
WHERE table_schema = 'public'
  AND grantee IN ('anon', 'authenticated')
ORDER BY table_name, grantee, privilege_type;
```

**4. RPC security model and search_path**
```sql
SELECT proname,
       prosecdef                          AS security_definer,
       proconfig                          AS config,
       pg_get_function_arguments(oid)     AS args
FROM pg_proc
WHERE pronamespace = 'public'::regnamespace
ORDER BY proname;
```

**5. Which RPCs anon / authenticated can call**
```sql
SELECT routine_name, grantee, privilege_type
FROM information_schema.role_routine_grants
WHERE routine_schema = 'public'
  AND grantee IN ('anon', 'authenticated', 'PUBLIC')
ORDER BY routine_name, grantee;
```

**What to look for**

| Query | Red flag |
|---|---|
| 1 | `OPEN` (no RLS) or `BLOCKED` (RLS on, no policies — all access denied) |
| 2 | `using_expr = true` (unrestricted read) or `with_check = true` (unrestricted write) |
| 3 | `INSERT`, `UPDATE`, or `DELETE` granted to `anon` or `authenticated` |
| 4 | `security_definer = true` and `config` does not contain `search_path=` |
| 5 | Any RPC callable by `anon` or `PUBLIC` |

---

## Commands

```bash
npm run dev           # Start dev server
npm run build         # Production build (uploads source maps to Sentry)
npm run preview       # Preview production build locally
npm run lint          # Run ESLint
npm run cleanup:preview
npm run cleanup:export
```
