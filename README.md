# Libber

A loyalty points app. Customers join stores and accumulate points. Staff award points and manage redemptions. Managers approve staff. Admins manage stores and rules.

---

## Next session

**Domain name decided: Gotya** (`gotya.ie` + `gotya.co.uk` registered). Rebrand from Libber to Gotya is pending.

**Plan:** rebuild on a new laptop with a new Google account (`gotya`), fresh Git repo, fresh Supabase project, fresh Vercel project. This repo is the reference blueprint.

### What is done (2026-05-25)

- ✅ **New Supabase project live** — `lib2` (`tcrbkylzbdpkgliacrlj`). Migrations 00–15 executed. App deployed and confirmed hitting new project (blank state, new user `RHH 791 052`).
- ✅ **Migration 16 — `unjoin_store`** — was missing from canonical rebuild; client called it but no SQL existed. Added as `16-unjoin-store.sql`, soft-removes membership (`is_active = false`).
- ✅ **Cloudflare env vars updated** — `VITE_SUPABASE_URL` + `VITE_SUPABASE_ANON_KEY` set in dashboard and committed to `.env` in git.
- ✅ **Canonical rebuild chain frozen at migration 16** — 16 numbered SQL files (`00`–`16`). `BASELINE.md`, `MIGRATIONS.md`, `verify-baseline.sql` all current.
- ✅ **Applicant system fully removed** — `store_staff_applicants`, `store_manager_applicants`, `apply_for_staff`, `reject_staff_applicant`, `admin_approve_applicant`, `admin_reject_applicant` absent from rebuild chain.
- ✅ **`assert_store_manager` NULL bypass fixed** — `COALESCE(get_store_role(...), '')` prevents authenticated users with no role from bypassing manager-only RPCs.
- ✅ **`load_customer_home` restored** — `logo_path` + `logo_updated_at` + `is_active` filtering all present in the final version (`14-soft-delete.sql`).
- ✅ **`on_auth_user_created` trigger created** — fires correctly on `auth.users` INSERT.
- ✅ **Migration governance** — `MIGRATIONS.md` (rules), `BASELINE.md` (frozen spec), `verify-baseline.sql` (drift detection).
- ✅ Gmail SMTP configured in Supabase — magic link emails working (500/day limit)
- ✅ Google OAuth configured — Google Cloud project `delta-discovery-593`, client `Libber`, redirect URI `https://flghcbrwqtburdywgcvk.supabase.co/auth/v1/callback` ⚠️ needs updating for new project
- ✅ Error handling for OAuth `email_exists` conflict — shows message instead of silent fail
- ✅ Migrated from Vercel to **Cloudflare Pages** — `_headers` / `_redirects` replace `vercel.json`
- ✅ QR code on customer staff overlay — staff can scan instead of reading alphanumeric ID
- ✅ Camera scanner on staff page — `jsqr` decodes QR from video feed, rear-camera preferred with fallback
- ✅ Multi-outlet support — `store_outlets` table, outlet picker on staff page, `outlet_id` tagged on every ledger row for analytics
- ✅ Admin outlet CRUD — create/rename/delete outlets inline in Manage Store panel
- ✅ RBAC helpers deployed — `get_store_role`, `assert_store_access`, `assert_store_manager` centralise all store permission checks across every RPC

### Pick up here next session

1. **Run in Supabase SQL editor (new project)**:
   - `16-unjoin-store.sql`
   - `15-final-grants.sql` (re-run after 16)
2. **Assign admin**: public ID is `RHH 791 052` — run `assign-admin.sql` with this value
3. **Enable anonymous auth**: Supabase Dashboard → Authentication → Providers → Anonymous → Enable (confirm it's on)
4. **Seed `ab_variants`**: insert at least 2 active rows for `test_name = 'save_prompt'` (see README SQL section)
5. **Set Auth URL config**: Dashboard → Authentication → URL Configuration → Site URL `https://libber.pages.dev`, Redirect URL `https://libber.pages.dev/apps/customer/save.html`
6. **Update Google OAuth redirect URI**: Google Cloud → OAuth client → add `https://tcrbkylzbdpkgliacrlj.supabase.co/auth/v1/callback`
7. **Configure Gmail SMTP**: re-enter in new project Dashboard → Authentication → SMTP settings
8. **Create stores** via admin tool and test full customer → staff flow

### Still outstanding

- **Apple OAuth** — requires paid Apple Developer account ($99/year). Services ID, `.p8` key, Team ID, Key ID → Supabase Auth → Apple
- **Automatic identity linking** — not configurable in Supabase dashboard. Without it, a user who saved via magic link cannot link Google in a second browser (`email_exists` error). Magic link cross-device works fine regardless.
- **Custom SMTP (Resend)** — currently using Gmail SMTP (500/day). Resend requires a custom domain — unblock after domain is set up.
- **Admin UI for outlet ordering** — outlets are currently alphabetical only. Manual ordering would require a `sort_order` column on `store_outlets`.
- **Rebrand to Gotya** — rename in code, Cloudflare, Supabase, Google Cloud, Sentry

---

## Architecture

Two separate web apps built from one codebase, deployed to one Vercel project.

| App | Audience | Root |
|---|---|---|
| **Customer** | End users — join stores, view balances, earn and redeem points | `apps/customer/` |
| **Staff** | Staff, managers — award points, promote/demote staff | `apps/staff/` |

**Admin tool** (`adminstart.html`) — local only, never deployed. Used to create stores, configure reward rules, assign managers, and manage store outlets.

---

## Pages

### Customer (`apps/customer/`)

| File | Purpose |
|---|---|
| `index.html` | Home — user ID, joined store balances, join/unjoin stores, save-prompt button, points history per store |
| `save.html` | Save account — Google, Apple, or email magic link |
| `settings.html` | Account — linked account status; link another account |

### Staff (`apps/staff/`)

| File | Purpose |
|---|---|
| `page.html` | Staff tools — load members, award/bonus/adjust points, redeem. QR scanner searches by scanned ID. Outlet picker shown when store has multiple outlets |
| `manager.html` | Manager tools — view store members, promote to staff, demote staff |

### Admin (local only)

`adminstart.html` — create stores, configure reward rules (with ordering), assign managers and staff, manage store outlets (create, rename, delete). Your public ID is shown at the top for use with `assign-admin.sql`.

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
    page.html
    manager.html
adminstart.html         Local admin tool (not deployed)
scripts/
  sql/                  All DB scripts (see SQL Scripts section)
src/
  lib/
    cog.js              PWA install logic — initCog() (dropdown toggle) + initInstallSection() (static section) — used by staff/manager pages
    confirm.js          showConfirm(title, detail) — reusable Promise-based confirm dialog
    dom.js              $ (getElementById), $q (querySelector), $$ (querySelectorAll)
    escape.js           escapeHtml — used before any user value hits the DOM
    format.js           Shared formatting helpers
    sentry.js           Sentry init, setSentryUser(), captureError()
    storage.js          Shared localStorage helpers
    supabase.js         Supabase client (anon key)
    theme.js            Theme utilities — default is `mid` (thumbnails visible)
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
    admin.js            Store, rule, outlet, and admin RPC calls
    applicants.js       loadManagedStores, approveApplicant (promote), demoteStaff, loadStaff
    auth.js             Anonymous auth bootstrap, resetSession() (dev only)
    members.js          loadUserProfile, loadCustomerHome, loadMembers, loadPointsHistory, awardPoints, adjustPoints
    staff.js            loadStaffStores (unions store_staff + store_managers), loadStoreOutlets
    stores.js           getStores, joinStore, unjoinStore, getStoreBonusCap
  state/state.js        Shared in-memory state
  ui/
    renderCustomers.js  Staff member panel — award, bonus, adjust, redeem
    renderStores.js     Store join/unjoin cards (with avatars on mid/max theme)
    renderUser.js       User ID header, joined-store cards, expandable history; exports storeAvatar()
    savePrompt.js       Save-prompt button — render(), glow()
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
| Deployment | Cloudflare Pages — auto-deploys on push to `main` |

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
  apps/staff/page.html
  apps/staff/manager.html
```

The admin tool is never built — run it locally in dev only.

---

## Deployment

Deployed on **Cloudflare Pages**. Auto-deploys on push to `main`.

- Framework preset: None
- Build command: `npm run build`
- Output directory: `dist`
- Production branch: `main`

Security headers and URL rewrites are in `public/_headers` and `public/_redirects` — Vite copies them to `dist/` at build time. `vercel.json` has been removed.

**Live URLs**

| Page | URL |
|---|---|
| Customer home | `https://libber.pages.dev` |
| Staff tools | `https://libber.pages.dev/apps/staff/` |
| Manager tools | `https://libber.pages.dev/apps/staff/manager.html` |

**Environment variables** (Cloudflare Pages → Settings → Environment Variables)

| Variable | Where to get it |
|---|---|
| `VITE_SUPABASE_URL` | Supabase Dashboard → Project Settings → API |
| `VITE_SUPABASE_ANON_KEY` | Supabase Dashboard → Project Settings → API |
| `SENTRY_AUTH_TOKEN` | Sentry → Settings → Auth Tokens |

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
3. A save-prompt button is shown once the user has earned any points (A/B tested text). Glows briefly when new points are detected. Tapping goes to `save.html` — Google, Apple, or email magic link
4. Tap a store card to expand: award rules, redeem options, last 10 transactions
5. Join or unjoin stores — points are preserved if the user rejoins later
6. Cog icon (top right) links to `settings.html` — shows linked account status

### Staff

1. Open `apps/staff/` — approved stores listed under "Your stores"
2. Click a store → goes to `page.html` for that store
3. Load members, click a member to open their panel, award points via rule buttons or bonus section
4. "← My Stores" returns to the store picker

### Manager

1. Open `apps/staff/manager.html`
2. Your managed stores are listed — click one to load all store members
3. Promote members to staff or demote existing staff members

### Admin (local)

1. Run dev server, open `http://localhost:5173/adminstart.html`
2. Copy your public ID at the top, run `assign-admin.sql` to grant yourself admin access
3. Create stores, configure reward rules (label, points, kind, order)
4. Assign and remove managers and staff
5. In Manage Store → Outlets: create, rename, and delete outlets for a store

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
| `store_outlets` | Physical outlets within a store (optional). Name only — analytics tag, not balance-affecting |
| `points_ledger` | Every points transaction. `outlet_id` nullable FK for per-outlet analytics. On `supabase_realtime` publication |
| `store_reward_rules` | Award and redeem rules per store |
| `ab_variants` | A/B test variant definitions |
| `admins` | Users with admin access |

---

## Supabase RPCs

All write operations go through RPCs. No direct client writes.

| RPC | Auth check | What it does |
|---|---|---|
| `join_store` | `auth.uid()` | Creates membership or reactivates an inactive one; blocks archived stores |
| `approve_staff_applicant` | Manager or admin | Promotes a member to staff |
| `demote_store_staff` | Manager or admin | Removes a user from store staff |
| `manager_remove_customer_from_store` | Manager or admin | Deactivates a customer's membership (soft-removes) |
| `award_points` | Staff, manager, or admin | Inserts ledger entry, enforces bonus cap, tags outlet if provided. Advisory lock per (user, store) |
| `adjust_points` | Staff, manager, or admin | Inserts correction (no cap). Advisory lock per (user, store) |
| `load_customer_home` | `auth.uid()` | Returns profile, memberships, balances, rules, history, save prompt data in one call. Filters inactive stores and memberships |
| `load_store_members` | Staff, manager, or admin | Returns active members with balances and public IDs |
| `load_store_staff_profiles` | Manager or admin | Returns staff with public IDs |
| `load_store_outlets` | Staff, manager, or admin | Returns outlets for a store |
| `load_member_recent_transactions` | Staff, manager, or admin | Returns last 5 ledger entries for a member at a store |
| `mark_account_linked` | `auth.uid()` | Sets `account_linked_at` on the caller's profile |
| `admin_create_store` | Admin | Creates a store |
| `admin_update_store` | Admin | Renames a store |
| `admin_remove_store` | Admin | Hard-deletes a store and all related data |
| `admin_archive_store` | Admin | Soft-deletes a store (`is_active = false`, sets `deleted_at`) |
| `admin_restore_store` | Admin | Restores an archived store (`is_active = true`, clears `deleted_at`) |
| `admin_set_store_logo` | Admin | Sets `logo_path` and `logo_updated_at` on a store |
| `admin_insert_reward_rule` | Admin | Adds a reward rule |
| `admin_delete_reward_rule` | Admin | Deletes a reward rule |
| `admin_update_reward_rule_order` | Admin | Updates rule sort order |
| `admin_set_bonus_cap` | Admin | Sets or clears the bonus cap for a store |
| `admin_assign_manager` | Admin | Assigns a user as manager |
| `admin_remove_manager` | Admin | Removes a manager |
| `admin_assign_staff` | Admin | Directly assigns a user as staff |
| `admin_remove_staff` | Admin | Removes a user from store staff |
| `admin_load_store_members` | Admin | Returns all members (active + inactive) for a store |
| `admin_create_outlet` | Admin | Creates an outlet for a store |
| `admin_update_outlet` | Admin | Renames an outlet |
| `admin_delete_outlet` | Admin | Deletes an outlet (ledger rows retain history via ON DELETE SET NULL) |
| `get_store_role` | — | STABLE helper: returns `'admin'`, `'manager'`, `'staff'`, or `null` for the caller at a given store |
| `assert_store_access` | — | Raises if caller has no role at the store (used inside RPCs) |
| `assert_store_manager` | — | Raises if caller is not manager or admin (used inside RPCs) |
| `assert_store_active` | — | Raises if store does not exist or is archived (used inside RPCs) |
| `assert_active_membership` | — | Raises if no active membership row exists for the (user, store) pair |
| `is_admin` | — | Helper: returns true if caller is in `admins` table |

**Views**

| View | Purpose |
|---|---|
| `admin_user_directory` | All users with public IDs |

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
| `stores` | ✓ | `admin_create_store`, `admin_update_store`, `admin_remove_store`, `admin_archive_store`, `admin_restore_store` |
| `store_reward_rules` | ✓ | `admin_insert_reward_rule`, `admin_delete_reward_rule`, `admin_update_reward_rule_order` |
| `store_memberships` | ✓ | `join_store`, `manager_remove_customer_from_store` |
| `store_staff` | ✓ | `approve_staff_applicant`, `demote_store_staff`, `admin_assign_staff`, `admin_remove_staff` |
| `store_managers` | ✓ | `admin_assign_manager`, `admin_remove_manager` |
| `store_outlets` | ✓ | `admin_create_outlet`, `admin_update_outlet`, `admin_delete_outlet` |
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
| `store_managers` | `user_id = auth.uid()` or admin |
| `admins` | Service role only — `is_admin()` reads via SECURITY DEFINER |

### Function grants

All public RPCs are callable by `authenticated` only. `anon` and `PUBLIC` have `EXECUTE` revoked on all public functions. Re-run `15-final-grants.sql` after any migration that creates or replaces functions — Supabase's `supabase_admin` default privileges restore broad grants on every `CREATE OR REPLACE FUNCTION`.

### XSS

All user-controlled values are escaped via `src/lib/escape.js` before being written to the DOM.

### Store-level RBAC

All store-scoped permission checks go through centralised helpers defined in `10-rbac-helpers.sql`:

| Helper | Returns / Raises |
|---|---|
| `get_store_role(p_store_id)` | `'admin'` · `'manager'` · `'staff'` · `null` |
| `assert_store_access(p_store_id)` | Raises if `get_store_role` returns null |
| `assert_store_manager(p_store_id)` | Raises if role is not `manager` or `admin` (`COALESCE`-guarded — NULL-safe) |
| `assert_store_active(p_store_id)` | Raises if store is archived or does not exist |
| `assert_active_membership(p_user_id, p_store_id)` | Raises if no active membership row exists |

Every guarded RPC calls the appropriate helper — no inline UNION queries. Adding a new role tier only requires editing `get_store_role`.

**NULL-safety note**: `assert_store_manager` uses `COALESCE(get_store_role(...), '')` before the `NOT IN` check. Without this, `NULL NOT IN ('manager', 'admin')` evaluates to NULL in SQL and the guard would silently pass for unauthenticated callers.

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

All scripts in `scripts/sql/`. Paste into Supabase Dashboard → SQL Editor.

### Canonical Build Files (00–15) — use these for fresh setup

Baseline frozen at migration 15. Files 00–15 are immutable. See `BASELINE.md` for the full spec and `MIGRATIONS.md` for governance rules.

| File | What it adds |
|---|---|
| `00-base-schema.sql` | 7 base tables + RLS enabled |
| `01-admin-security.sql` | `admins` table, `is_admin()`, write-block RLS on stores/rules, admin RPCs |
| `02-rls-policies.sql` | SELECT policies on all base tables |
| `03-rls-write-blocks.sql` | Write-block RLS on memberships/staff/ledger; early `join_store`, `demote_store_staff` |
| `04-schema-bonus-cap.sql` | `stores.max_bonus_points`; `admin_set_bonus_cap`; `award_points` (intermediate) |
| `05-schema-bonus-adjust.sql` | Extends kind constraint; `adjust_points` (intermediate) |
| `06-schema-outlets.sql` | `store_outlets` table; `outlet_id` on `points_ledger`; outlet RPCs |
| `07-schema-ab-testing.sql` | `ab_variants` table; profile columns; `create_profile` trigger |
| `08-schema-store-logo.sql` | `stores.logo_path`/`logo_updated_at`; storage bucket + policies; `admin_set_store_logo` |
| `09-rpc-save-account.sql` | `mark_account_linked` RPC |
| `10-rbac-helpers.sql` | `get_store_role`, `assert_store_access`, `assert_store_manager`; RBAC indexes |
| `11-security-hardening.sql` | Realtime; scoped RLS; REVOKE anon; grant lockdown |
| `12-admin-user-directory.sql` | `admin_user_directory` view; `profiles: select as admin` policy |
| `13-rpc-fixes.sql` | `load_member_recent_transactions`; advisory lock on `adjust_points` |
| `14-soft-delete.sql` | `is_active` columns; `assert_store_active`/`assert_active_membership`; all final RPCs |
| `15-final-grants.sql` | Final REVOKE anon/PUBLIC + re-grant authenticated on all functions |

### Utility Scripts

| Script | What it does |
|---|---|
| `assign-admin.sql` | Grants admin access by public ID |
| `revoke-admin-store-access.sql` | Safely revokes admin + all store access for a user. Dry-run by default (`v_dry_run = true`) |
| `delete-store.sql` | Deletes one store and all its data |
| `delete-user.sql` | Deletes one user by public ID |
| `delete-all-users.sql` | Deletes all users. Leaves stores and rules intact |
| `reset-all.sql` | Full wipe — every row including auth users. No undo |
| `verify-baseline.sql` | Drift-detection queries — every section returns rows only when something is wrong |

### Legacy / Reference Scripts

Kept for history only. Do not run these on a fresh setup — the canonical files above supersede them.

| Script | Notes |
|---|---|
| `admin-rpcs.sql` | Superseded by `01-admin-security.sql` |
| `staff-rpcs.sql` | Superseded by `03-rls-write-blocks.sql` |
| `add-bonus-cap.sql` | Superseded by `04-schema-bonus-cap.sql` |
| `add-rls-select-policies.sql` | Superseded by `02-rls-policies.sql` |
| `add-ab-testing.sql` | Superseded by `07-schema-ab-testing.sql` |
| `add-bonus-adjust.sql` | Superseded by `05-schema-bonus-adjust.sql` |
| `add-save-account.sql` | Superseded by `09-rpc-save-account.sql` |
| `add-outlets.sql` | Superseded by `06-schema-outlets.sql` |
| `add-store-logo.sql` | Superseded by `08-schema-store-logo.sql` |
| `add-rbac-helpers.sql` | Superseded by `10-rbac-helpers.sql` (also has the COALESCE NULL-safety fix) |
| `harden-rls-and-grants.sql` | Superseded by `11-security-hardening.sql` |
| `fix-admin-user-directory.sql` | Superseded by `12-admin-user-directory.sql` |
| `fix-rbac-remaining.sql` | Superseded by `13-rpc-fixes.sql` |
| `fix-default-privileges.sql` | Superseded by `15-final-grants.sql` |
| `add-soft-delete-v4.sql` | Superseded by `14-soft-delete.sql` |
| `add-manager-applicants.sql` | Historical — applicant system removed from rebuild |
| `add-load-customer-home-rpc.sql` | Historical |
| `add-load-store-members-rpc.sql` | Historical |
| `add-reject-applicant-rpc.sql` | Historical — `reject_staff_applicant` removed from rebuild |
| `add-load-store-staff-profiles-rpc.sql` | Historical |
| `add-load-member-recent-transactions-rpc.sql` | Historical |
| `rename-account-linked.sql` | Historical migration — already baked into canonical files |
| `remove-applicant-table-refs.sql` | Historical — applicant system removed from rebuild |
| `drop-applicant-system.sql` | Historical — applicant system removed from rebuild |
| `admin-load-store-members.sql` | Historical |
| `fix-approve-staff-applicant.sql` | Historical security fix — baked into canonical files |
| `fix-award-points-security.sql` | Historical security fix — baked into canonical files |
| `fix-soft-delete-consistency.sql` | Historical — baked into `14-soft-delete.sql` |
| `bootstrap-admin-store-access.sql` | Historical utility |

---

## Fresh Setup

### New Supabase project — run scripts in this order

Run the 16 canonical migration files in `scripts/sql/` in order. Paste each into Supabase Dashboard → SQL Editor.

```
00-base-schema.sql
01-admin-security.sql
02-rls-policies.sql
03-rls-write-blocks.sql
04-schema-bonus-cap.sql
05-schema-bonus-adjust.sql
06-schema-outlets.sql
07-schema-ab-testing.sql
08-schema-store-logo.sql
09-rpc-save-account.sql
10-rbac-helpers.sql
11-security-hardening.sql
12-admin-user-directory.sql
13-rpc-fixes.sql
14-soft-delete.sql
15-final-grants.sql   ← always run last (re-revokes anon/PUBLIC; defeats Supabase default-privilege re-grant)
```

Then:

1. Open `adminstart.html` locally, copy your public ID
2. Run `assign-admin.sql` to grant yourself admin access
3. Reload admin tool — create stores, configure rules, assign managers, manage outlets

The authoritative spec for the resulting schema is `scripts/sql/BASELINE.md`.

### After a full reset (`reset-all.sql`)

Schema (RPCs, RLS, triggers) survive a data reset — they live in the schema, not the data. Re-run `15-final-grants.sql` only.

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
