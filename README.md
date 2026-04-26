# Libber

Libber is a loyalty points app built with Vite and Supabase.

---

## Two-App Architecture

The project builds two separate web apps from one codebase:

| App | Audience | Entry |
|---|---|---|
| **Customer** | End users joining stores and viewing points | `apps/customer/` |
| **Staff** | Staff awarding points, managers approving applicants | `apps/staff/` |

The **admin tool** (`adminstart.html`) lives at the repo root and is run locally only by the repo owner — it is not deployed and is not intended for other users. It is used to create stores, configure reward rules, and assign managers.

---

## Pages

### Customer app (`apps/customer/`)
- `index.html` — shows the user's ID, joined stores, balances, and available stores to join. Includes a persistent save-prompt button (A/B tested text, only shown once the user has earned points) that glows when new points are detected. Tapping the ID area shows a full-screen staff view. A hidden dev section (7 taps on the footer strip) exposes a staff page link and a session reset button for testing.

### Staff app (`apps/staff/`)
- `index.html` — pick a store you work at (staff or manager) and click it to open staff tools, or apply for access to a new store. Managers also see a "Go to manager tools →" link.
- `page.html` — staff tools: load members, award points via store-configured buttons. "← My Stores" button returns to the store picker.
- `manager.html` — manager tools: see managed stores, approve/reject applicants, view and remove current staff, apply to manage new stores. Includes refresh button.

### Admin (local only)
- `adminstart.html` — create stores, configure reward rules (with ordering), assign managers. Your public ID is shown at the top of the page — used when running `assign-admin.sql`.

---

## Project Structure

```
apps/
  customer/
    index.html
  staff/
    index.html
    page.html
    manager.html
scripts/
  sql/
    admin-rpcs.sql                   RLS + RPC setup for stores, reward rules, admin RPCs
    staff-rpcs.sql                   RLS + RPC setup for memberships, staff, ledger
    add-manager-applicants.sql       Manager application flow + RPCs
    add-bonus-cap.sql                Per-store bonus cap column + award_points RPC
    add-rls-select-policies.sql      SELECT RLS policies for all client-read tables
    add-load-customer-home-rpc.sql   load_customer_home RPC (baseline version)
    add-load-store-members-rpc.sql   load_store_members RPC
    add-reject-applicant-rpc.sql     reject_staff_applicant RPC
    add-ab-testing.sql               A/B testing framework, save prompt variants, updated load_customer_home
    assign-admin.sql                 Grant admin access by public ID
    delete-store.sql                 Delete one store and all its data
    delete-user.sql                  Delete one user by public ID
    delete-all-users.sql             Delete all users, preserve stores and rules
    reset-all.sql                    Full wipe of all data
src/
  lib/
    escape.js         shared escapeHtml utility
    storage.js        shared localStorage helpers
    supabase.js       Supabase client
  pages/
    admin/
      start.js        admin page controller
    customer/
      main.js         customer page controller
    manager/
      start.js        manager page controller
    staff/
      start.js        staff apply/store picker page controller
      page.js         staff tools page controller
  services/
    admin.js          store creation, reward rules, admin RPCs
    applicants.js     apply_for_staff, loadApplicants, loadMyApplications, loadStaff, approveApplicant, demoteStaff, applyForManager, loadMyManagerApplications
    auth.js           anonymous auth bootstrap, resetSession() for dev testing
    members.js        loadMembers, loadUserProfile, loadCustomerHome, awardPoints, adjustPoints, loadPointsHistory
    staff.js          loadStaffStores (unions store_staff + store_managers)
    stores.js         getStores, joinStore, getStoreBonusCap
  state/
    state.js          shared in-memory state
  ui/
    renderCustomers.js
    renderStores.js
    renderUser.js
    savePrompt.js     save-prompt module: render(data), glow()
adminstart.html         local admin tool (not deployed)
vite.config.js          multi-page build config
```

---

## Stack

- Vite
- Vanilla JavaScript
- Supabase (`@supabase/supabase-js`)

---

## Local Setup

1. Install dependencies:

```bash
npm install
```

2. Create a `.env` file with your Supabase credentials:

```bash
VITE_SUPABASE_URL=your_supabase_project_url
VITE_SUPABASE_ANON_KEY=your_supabase_anon_key
```

3. Start the dev server:

```bash
npm run dev
```

4. Open pages in the browser:

| Page | URL |
|---|---|
| Customer app | `http://localhost:5173/apps/customer/` |
| Staff store picker | `http://localhost:5173/apps/staff/` |
| Staff tools | `http://localhost:5173/apps/staff/page.html` (navigated to by clicking a store) |
| Manager tools | `http://localhost:5173/apps/staff/manager.html` |
| Admin (local) | `http://localhost:5173/adminstart.html` |

---

## Build

```bash
npm run build
```

Vite builds four separate bundles defined in `vite.config.js`:

```
dist/
  apps/customer/index.html    ← deploy to customer domain
  apps/staff/index.html       ← deploy to staff domain
  apps/staff/page.html
  apps/staff/manager.html
```

The admin tool is never built for deployment — run it locally from dev only.

---

## Deployment (Vercel)

| Page | URL |
|---|---|
| Customer app | https://libber.vercel.app |
| Staff store picker | https://libber.vercel.app/apps/staff/ |
| Staff tools | https://libber.vercel.app/apps/staff/page.html |
| Manager | https://libber.vercel.app/apps/staff/manager.html |

Deployed via Vercel — auto-deploys on push to `main`.

- Framework preset: **Vite** (auto-detected)
- Build command: `npm run build`
- Output directory: `dist` (auto-detected)
- Root directory: `./`

### Environment variables (set in Vercel dashboard → Settings → Environment Variables)

| Variable | Value |
|---|---|
| `VITE_SUPABASE_URL` | `https://flghcbrwqtburdywgcvk.supabase.co` |
| `VITE_SUPABASE_ANON_KEY` | Supabase publishable key (Dashboard → Project Settings → API) |

The root redirect (`/` → `/apps/customer/`) is handled by `vercel.json`:

```json
{
  "rewrites": [
    { "source": "/", "destination": "/apps/customer/index.html" }
  ]
}
```

---

## Auth Model

The app uses anonymous Supabase auth (`src/services/auth.js`):

- A visitor gets or restores an anonymous Supabase session automatically — no signup required
- All role assignment is tied to that Supabase `auth.uid()`
- A `create_profile` database trigger fires on every new auth user, inserting a row into `profiles` with a generated human-readable `public_id` (e.g. `MQH 335 484`) and a weighted-random A/B test variant assignment
- If a stored JWT references a deleted user, `initAuth()` detects the error, signs out, and creates a fresh anonymous session automatically
- The trigger fires regardless of which page the user first visits — every new anonymous session gets a profile

---

## Current Product Flow

### Customer
1. Open `apps/customer/`
2. Anonymous auth initialises, profile created automatically
3. Joined stores with balances load instantly from cache, then refresh from the server
4. A save-prompt button is visible in the header area (A/B tested text). It glows briefly whenever new points are detected — a subtle prompt that persists until the user saves their account
5. Tap a store card to expand:
   - **How to earn** — the store's award rules (e.g. "1 coffee → +5 pts")
   - **Rewards** — the store's redeem options and their point costs
   - **Transaction history** — last 10 entries in chronological order, colour-coded by type: award (green), redeem (purple), bonus (amber), adjust (blue)
6. Join additional stores from the "Join a store" section

### Staff (applying)
1. Open `apps/staff/`
2. "Your stores" section shows stores you're already approved for (as staff or manager) — click one to go straight to staff tools
3. "Apply for a new store" section: pick a store and apply
4. If already applied but not yet approved: button shows "Pending approval"
5. On manager approval: store appears in "Your stores"

### Staff (awarding points)
1. Click a store from "Your stores" on the staff index
2. Members and reward rules load for that store
3. Click a member to open their panel
4. Award points via quick-award buttons, bonus section (configurable reasons + amounts), or adjust (free-form positive/negative correction)
5. "← My Stores" returns to the store picker
6. Member filter only appears when the store has 10 or more members

### Manager
1. Open `apps/staff/manager.html` (linked from staff index via "Go to manager tools →")
2. "Your stores" shows all stores you manage
3. Click a store to load its applicants and current staff
4. Approve or reject applicants; remove staff members if needed
5. Refresh button reloads applicants and staff without a full page reload
6. Apply to manage additional stores from the bottom section
7. "Go to staff page →" links back to the staff index to use staff tools

### Admin (local)
1. Open `adminstart.html` in dev (`http://localhost:5173/adminstart.html`)
2. Your public ID is shown at the top — copy it for `assign-admin.sql`
3. Create stores
4. Configure reward rules per store (label, points, kind, ordering)
5. Assign and remove managers and staff
6. View all users and manager applicants

---

## Points Model

Points are **not fungible across stores**. 50 pts at Store A cannot be combined with or used at Store B. Each store's balance is independent.

---

## Reward Rules

Staff page buttons are driven by `store_reward_rules` in Supabase — not hardcoded. Configured per store in the admin tool.

- `kind = 'award'` — quick-award buttons (label + points, reason auto-set to label)
- `kind = 'redeem'` — redemption buttons (label + point cost)
- `kind = 'bonus_reason'` — configurable reason options for the bonus section (label only, no point value)
- `kind = 'bonus_amount'` — configurable amount buttons for the bonus section (point value, no label needed)

Staff must pick one bonus reason and one bonus amount to enable the award. The per-store bonus cap (`max_bonus_points`) applies to bonus awards and limits the visible amount buttons. Quick-award buttons bypass the cap.

---

## Transaction History

Each store card on the customer page shows the last 10 transactions in reverse-chronological order. Transactions are colour-coded by type, inferred at render time from the points value and reason against the store's active rules — no extra DB column needed.

| Type | Colour | How identified |
|---|---|---|
| Award | Green | Points > 0 and reason matches an `award` rule label |
| Redeem | Purple | Points < 0 |
| Bonus | Amber | Points > 0 and reason matches a `bonus_reason` rule label |
| Adjust | Blue | Everything else (free-form staff correction) |

---

## A/B Testing

The `ab_variants` table drives configurable experiments. The save prompt is the first experiment (`test_name = 'save_prompt'`).

### How it works

- Each row defines one variant: `test_name`, `variant` (label), `text`, `position`, `weight`, `is_active`
- Variant assigned once at profile creation using Efraimidis-Spirakis weighted reservoir sampling (`pow(random(), 1.0/weight)`) — mathematically correct proportional selection
- The `load_customer_home` RPC looks up the variant's current text and position from the table on every call — so text/position changes take effect immediately without reassigning variants
- If a variant is deactivated (`is_active = false`) or deleted, `load_customer_home` returns `save_prompt: null` and the client hides the prompt

### Adding or changing variants

Edit rows in the `ab_variants` table via the Supabase dashboard:
- Add a new row with a new `variant` label and `weight`
- Change `text` or `position` — takes effect immediately for all users assigned that variant
- Set `is_active = false` to deactivate a variant without deleting it
- Adjust `weight` to shift traffic allocation (only affects new profiles; existing assignments are unchanged)

### Current save_prompt variants

| Variant | Text | Position | Weight |
|---|---|---|---|
| A | Save your points | middle | 50 |
| B | Don't lose your points | middle | 50 |

---

## Save Prompt

The save prompt is a persistent button on the customer home page that encourages users to save their account (link their anonymous session to an email address).

### Behaviour

- Only shown once the user has at least one point at any store — hidden on first visit until points are earned
- Hidden permanently once `email_saved_at` is set on the profile
- Text and position come from the assigned `ab_variants` row — configurable without a deploy
- **Glow effect**: each time the page loads or refreshes and new points are detected (balance increased since last cache), the button glows briefly — a subtle visual nudge. Repeats on every new-points event until the user saves their account
- Glow is suppressed on the very first load (no previous cache to compare against) to avoid false positives

### Implementation

- `src/ui/savePrompt.js` — self-contained module. Private state (`_visible`, `_emailSaved`, `_animating`, `_mounted`) avoids DOM inspection for state
- `render(data)` — called on every data load (cache and fresh). Guards against old cache format using `'save_prompt' in data` key presence check
- `glow()` — triggers CSS `box-shadow` keyframe animation. No conflict with `color`/`border-color` hover transitions

---

## Supabase Tables

| Table | Purpose |
|---|---|
| `profiles` | Human-readable public ID per user, A/B variant assignment, email save tracking |
| `stores` | Store records |
| `store_memberships` | Which users are members of which stores |
| `store_staff` | Approved staff per store |
| `store_managers` | Approved managers per store |
| `store_staff_applicants` | Pending staff applications |
| `store_manager_applicants` | Pending manager applications |
| `points_ledger` | Every points transaction with running balance |
| `store_reward_rules` | Award and redeem rules per store |
| `admins` | Users with admin access |
| `ab_variants` | A/B test variant definitions (text, position, weight, active flag) |

### Profile columns added by `add-ab-testing.sql`

| Column | Purpose |
|---|---|
| `save_prompt_variant` | Assigned A/B variant label (e.g. `'A'`) |
| `interaction_count` | Cumulative points interactions (for future threshold triggers) |
| `one_time_prompt_shown_at` | When the one-time popup was shown (future use) |
| `prompt_dismissed_at` | When the user dismissed the popup (future use) |
| `email_saved_at` | When the user saved their email — hides the prompt permanently |

---

## Supabase RPCs / Views

| Name | Auth check | What it does |
|---|---|---|
| `join_store` | `auth.uid()` required | Creates store membership for caller |
| `apply_for_staff` | `auth.uid()` required | Creates staff applicant record for caller |
| `apply_for_manager` | `auth.uid()` required | Creates manager applicant record for caller |
| `approve_staff_applicant` | Must be manager of the store | Promotes applicant to staff, removes from applicants |
| `reject_staff_applicant` | Must be manager of the store | Rejects and removes a staff applicant |
| `demote_store_staff` | Must be manager of the store | Removes a user from store staff |
| `award_points` | Must be staff or manager of the store | Inserts points ledger entry, enforces bonus cap |
| `adjust_points` | Must be staff or manager of the store | Inserts a positive or negative correction entry, no cap check |
| `load_customer_home` | `auth.uid()` required | Returns profile, memberships, balances, rules, history, save_prompt variant, email_saved flag in one call |
| `load_store_members` | Must be staff or manager of the store | Returns members with balances and public IDs |
| `admin_assign_manager` | Must be in `admins` table | Assigns a user as manager, clears their applicant record |
| `admin_reject_manager_applicant` | Must be in `admins` table | Rejects a manager applicant |
| `admin_create_store` | Must be in `admins` table | Creates a store |
| `admin_update_store` | Must be in `admins` table | Renames a store |
| `admin_remove_store` | Must be in `admins` table | Deletes a store and all related data |
| `admin_insert_reward_rule` | Must be in `admins` table | Adds a reward rule to a store |
| `admin_delete_reward_rule` | Must be in `admins` table | Deletes a reward rule |
| `admin_update_reward_rule_order` | Must be in `admins` table | Updates sort order of a reward rule |
| `admin_set_bonus_cap` | Must be in `admins` table | Sets or clears the bonus cap for a store |
| `admin_assign_staff` | Must be in `admins` table | Directly assigns a user as staff |
| `admin_remove_staff` | Must be in `admins` table | Removes a user from store staff |
| `admin_remove_manager` | Must be in `admins` table | Removes a manager from a store |
| `admin_approve_applicant` | Must be in `admins` table | Approves a staff applicant |
| `admin_reject_applicant` | Must be in `admins` table | Rejects a staff applicant |
| `is_admin` | — | Helper: returns true if caller is in `admins` table |
| `admin_user_directory` | View | Lists all users with public IDs (used by admin tool) |
| `staff_applicant_directory` | View | Lists applicants per store with public IDs |
| `create_profile` | Trigger on `auth.users` | Auto-creates a profile with generated public_id and weighted A/B variant on new user |

---

## Security

### Pattern

All write operations go through `SECURITY DEFINER` RPCs. RESTRICTIVE RLS policies block direct client writes to every table. The auth/permission check lives inside the RPC. No service role key is ever used in the browser.

- Client calls RPC → RPC checks `auth.uid()` / `is_admin()` → writes to table
- Direct client INSERT/UPDATE/DELETE → blocked by RESTRICTIVE RLS policy

### What is secured

| Table | Direct writes | Via RPC |
|---|---|---|
| `stores` | Blocked | `admin_create_store`, `admin_update_store`, `admin_remove_store` |
| `store_reward_rules` | Blocked | `admin_insert_reward_rule`, `admin_delete_reward_rule`, `admin_update_reward_rule_order` |
| `store_memberships` | Blocked | `join_store` |
| `store_staff` | Blocked | `approve_staff_applicant`, `demote_store_staff`, `admin_assign_staff`, `admin_remove_staff` |
| `store_managers` | Blocked | `admin_assign_manager`, `admin_remove_manager` |
| `store_staff_applicants` | Blocked | `apply_for_staff`, `approve_staff_applicant`, `reject_staff_applicant`, `admin_approve_applicant`, `admin_reject_applicant` |
| `store_manager_applicants` | Blocked | `apply_for_manager`, `admin_assign_manager`, `admin_reject_manager_applicant` |
| `points_ledger` | Blocked | `award_points`, `adjust_points` |
| `ab_variants` | Blocked | Managed via Supabase dashboard only |

### SELECT RLS policies

All tables readable by the client have explicit SELECT policies:

| Table | Policy |
|---|---|
| `profiles` | `USING (true)` — public IDs are intentionally shareable |
| `stores` | `USING (true)` |
| `store_reward_rules` | `USING (true)` |
| `store_staff` | `USING (true)` |
| `store_staff_applicants` | `USING (true)` |
| `ab_variants` | `USING (true)` — variant data is non-sensitive |
| `store_memberships` | `USING (user_id = auth.uid())` |
| `points_ledger` | `USING (user_id = auth.uid())` |
| `store_managers` | `USING (user_id = auth.uid() OR is_admin())` |
| `store_manager_applicants` | `USING (user_id = auth.uid() OR is_admin())` |
| `admins` | Service role only |

### Admin identity

Admin RPCs check `is_admin()` — a `SECURITY DEFINER` helper that looks up `auth.uid()` in the `admins` table. To grant admin access, run `scripts/sql/assign-admin.sql` with the target user's public ID.

### XSS

All user-controlled values are escaped via `src/lib/escape.js` before being written to the DOM.

---

## SQL Scripts

All scripts in `scripts/sql/` — paste into Supabase Dashboard → SQL Editor and run. All are safe to re-run (idempotent).

| Script | What it does |
|---|---|
| `admin-rpcs.sql` | Creates `admins` table, `is_admin()` helper, RESTRICTIVE RLS on `stores` and `store_reward_rules`, all admin RPCs |
| `staff-rpcs.sql` | RESTRICTIVE RLS on `store_memberships`, `store_staff`, `store_staff_applicants`, `points_ledger`. Staff and manager RPCs as SECURITY DEFINER |
| `add-manager-applicants.sql` | `store_manager_applicants` table, `apply_for_manager` RPC, `admin_assign_manager` and `admin_remove_store` (authoritative versions) |
| `add-bonus-cap.sql` | `max_bonus_points` column on `stores`, `award_points` RPC (authoritative version with cap logic), `admin_set_bonus_cap` RPC |
| `add-rls-select-policies.sql` | SELECT RLS policies for all client-read tables |
| `add-load-customer-home-rpc.sql` | `load_customer_home` RPC (baseline — superseded by `add-ab-testing.sql`) |
| `add-load-store-members-rpc.sql` | `load_store_members` RPC |
| `add-reject-applicant-rpc.sql` | `reject_staff_applicant` RPC |
| `add-ab-testing.sql` | `ab_variants` table + RLS, new profile columns, updated `create_profile` trigger with weighted variant assignment, updated `load_customer_home` with save prompt fields, backfill for existing profiles |
| `add-bonus-adjust.sql` | Extends `store_reward_rules_kind_check` to include `bonus_reason` and `bonus_amount`, drops stale `points > 0` constraint if present, adds `adjust_points` RPC |
| `assign-admin.sql` | Grants admin access to a user by their human-readable public ID |
| `delete-store.sql` | Deletes one store and all its memberships, staff, rules, and ledger entries |
| `delete-user.sql` | Deletes one user and all their data by public ID |
| `delete-all-users.sql` | Deletes all users and their data. Leaves stores and reward rules intact |
| `reset-all.sql` | Full wipe — every row in every table including auth users. No undo |

---

## Fresh Setup / Reset Workflow

### First time (new Supabase project)

Run scripts in this order:

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
11. Open `adminstart.html` locally, copy your public ID, run `assign-admin.sql`
12. Reload admin tool — create stores, configure rules, assign managers

### After a full reset (`reset-all.sql`)

The RPC and RLS setup survives a reset — it lives in the schema, not the data. Only re-do steps 10–11 above.

---

## DB Security Audit Queries

Run these in the Supabase Dashboard → SQL Editor to audit auth and RLS posture.

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

**3. Direct table grants to anon / authenticated**
```sql
SELECT table_name, grantee, privilege_type
FROM information_schema.role_table_grants
WHERE table_schema = 'public'
  AND grantee IN ('anon', 'authenticated')
ORDER BY table_name, grantee, privilege_type;
```

**4. All public RPCs — security model and search_path**
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
  AND grantee IN ('anon', 'authenticated')
ORDER BY routine_name, grantee;
```

**What to look for:**

| Query | Red flag |
|---|---|
| 1 | `status = OPEN` (no RLS) or `BLOCKED` (RLS on but no policies — all access denied) |
| 2 | `using_expr = true` (unrestricted read) or `with_check = true` (unrestricted write) |
| 3 | `INSERT`, `UPDATE`, or `DELETE` granted directly to `anon` or `authenticated` |
| 4 | `security_definer = true` and `config` does not include `search_path=` |
| 5 | Any RPC callable by `anon` that was not intended to be public |

---

## Commands

```bash
npm run dev
npm run build
npm run preview
npm run cleanup:preview
npm run cleanup:export
```
