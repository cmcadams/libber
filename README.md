# Libber

Libber is a loyalty points app built with Vite and Supabase.

---

## Two-App Architecture

The project builds two separate web apps from one codebase:

| App | Audience | Entry |
|---|---|---|
| **Customer** | End users joining stores and viewing points | `apps/customer/` |
| **Staff** | Staff applying, staff awarding points, managers approving | `apps/staff/` |

The **admin tool** (`adminstart.html`) lives at the repo root and is run locally only by the repo owner — it is not deployed and is not intended for other users. It is used to create stores, configure reward rules, and assign managers.

---

## Pages

### Customer app (`apps/customer/`)
- `index.html` — shows the user's ID, joined stores, balances, and available stores to join

### Staff app (`apps/staff/`)
- `index.html` — staff apply page: pick a store, apply for staff access, or open staff tools if already approved
- `page.html` — staff tools: load members, award points via store-configured buttons
- `manager.html` — manager tools: see managed stores, approve applicants, view current staff

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
    admin-rpcs.sql       one-time RLS + RPC setup (stores, reward rules, admin RPCs)
    staff-rpcs.sql       one-time RLS + RPC setup (memberships, staff, ledger)
    assign-admin.sql     grant admin access by public ID
    delete-store.sql     delete one store and all its data
    delete-user.sql      delete one user by public ID
    delete-all-users.sql delete all users, preserve stores and rules
    reset-all.sql        full wipe of all data
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
      start.js        staff apply page controller
      page.js         staff tools page controller
  services/
    admin.js          store creation, reward rules, admin RPCs
    applicants.js     apply_for_staff, loadApplicants, loadMyApplications, loadStaff, approveApplicant, demoteStaff
    auth.js           anonymous auth bootstrap
    members.js        loadMembers, loadUserProfile, awardPoints, loadPointsHistory
    staff.js          loadStaffStores
    stores.js         getStores, joinStore
  state/
    state.js          shared in-memory state
  ui/
    renderCustomers.js
    renderStores.js
    renderUser.js
adminstart.html         local admin tool (not deployed)
vite.config.js          multi-page build config
netlify.toml            build config + root redirect to customer app
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
| Staff apply | `http://localhost:5173/apps/staff/` |
| Staff tools | `http://localhost:5173/apps/staff/page.html` (navigated to automatically from staff apply) |
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
| Staff apply | https://libber.vercel.app/apps/staff/ |
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

`netlify.toml` and `public/_redirects` are kept in the repo but not used by Vercel.

---

## Auth Model

The app uses anonymous Supabase auth (`src/services/auth.js`):

- A visitor gets or restores an anonymous Supabase user
- All role assignment is tied to that Supabase `auth.uid()`
- Anonymous auth is fine for customers (nothing sensitive)
- Staff and managers also use anonymous auth — their identity is tied to the device/browser. If a staff member loses their token (cleared browser data, new device), they re-apply via the staff page and send their new `public_id` to the manager to approve again. This is an acceptable edge case — no real sign-in required.

---

## Current Product Flow

### Customer
1. Open `apps/customer/`
2. Anonymous auth initialises
3. Profile and joined stores with balances load
4. Tap a store card to expand:
   - **How to earn** — the store's award rules (e.g. "1 coffee → +5 pts")
   - **Rewards** — the store's redeem options and their point costs
   - **Transaction history** — last 20 entries
5. User can join additional stores — "Join a store" section is hidden once all stores are joined

### Staff Applicant
1. Open `apps/staff/`
2. Top section shows stores you're already approved for — click one to go straight to staff tools
3. Bottom section: pick a store and apply
4. If already applied but not yet approved: button shows "Pending approval"
5. On approval by manager: store appears in your approved list

### Manager
1. Open `apps/staff/manager.html`
2. Pick a managed store
3. Review applicants → approve to promote to staff
4. View current staff — remove a staff member if needed
5. Use "Go to staff tools →" to jump directly to the staff tools page

### Staff (awarding points)
1. Open `apps/staff/page.html` (navigated to from the apply page)
2. Selected store loaded from localStorage
3. Members and reward rules load
4. Award points using quick-award or bonus buttons

### Admin (local)
1. Open `adminstart.html` in dev (`http://localhost:5173/adminstart.html`)
2. Your public ID is shown at the top — copy it for `assign-admin.sql`
3. Create stores
4. Configure reward rules per store (label, points, kind, ordering)
5. Assign managers to stores

---

## Points Model

Points are **not fungible across stores**. 50 pts at Store A cannot be combined with or used at Store B. Each store's balance is independent. Do not display a combined total.

---

## Reward Rules

Staff page buttons are driven by `store_reward_rules` in Supabase — not hardcoded. Configured per store in the admin tool.

- `kind = 'award'` — quick-award buttons (label + points, reason auto-set to label)
- `kind = 'redeem'` — redemption buttons (points only, staff enters reason manually)

---

## Supabase Tables

- `profiles`
- `stores`
- `store_memberships`
- `store_staff`
- `store_managers`
- `store_staff_applicants`
- `points_ledger`
- `store_reward_rules`
- `admins`

## Supabase RPCs / Views

| Name | Auth check | What it does |
|---|---|---|
| `join_store` | `auth.uid()` required | Creates store membership for caller |
| `award_points` | Must be staff of the store | Inserts points ledger entry |
| `apply_for_staff` | `auth.uid()` required | Creates applicant record for caller |
| `approve_staff_applicant` | Must be manager of the store | Promotes applicant to staff, removes from applicants |
| `demote_store_staff` | Must be manager of the store | Removes a user from store staff |
| `admin_assign_manager` | Must be in `admins` table | Assigns a user as manager of a store |
| `admin_create_store` | Must be in `admins` table | Creates a store |
| `admin_update_store` | Must be in `admins` table | Renames a store |
| `admin_remove_store` | Must be in `admins` table | Deletes a store and all related data |
| `admin_insert_reward_rule` | Must be in `admins` table | Adds a reward rule to a store |
| `admin_delete_reward_rule` | Must be in `admins` table | Deletes a reward rule |
| `admin_update_reward_rule_order` | Must be in `admins` table | Updates sort order of a reward rule |
| `admin_assign_staff` | Must be in `admins` table | Directly assigns a user as staff |
| `admin_remove_staff` | Must be in `admins` table | Removes a user from store staff |
| `admin_remove_manager` | Must be in `admins` table | Removes a manager from a store |
| `admin_approve_applicant` | Must be in `admins` table | Approves a staff applicant |
| `admin_reject_applicant` | Must be in `admins` table | Rejects a staff applicant |
| `admin_user_directory` | View | Lists all users (used by admin tool) |
| `staff_applicant_directory` | View | Lists applicants per store |
| `create_profile` | Trigger | Auto-creates a profile with public_id on new auth user |

---

## Security

### Pattern

All write operations go through `SECURITY DEFINER` RPCs. RESTRICTIVE RLS policies block direct client writes to every table. The auth/permission check lives inside the RPC. No service role key is ever used in the browser.

- Client calls RPC → RPC checks `auth.uid()` / `is_admin()` → writes to table
- Direct client INSERT/UPDATE/DELETE → blocked by RESTRICTIVE RLS policy

### What is secured

| Table | Direct writes | Via RPC |
|---|---|---|
| `stores` | Blocked (RESTRICTIVE) | `admin_create_store`, `admin_update_store`, `admin_remove_store` |
| `store_reward_rules` | Blocked (RESTRICTIVE) | `admin_insert_reward_rule`, `admin_delete_reward_rule`, `admin_update_reward_rule_order` |
| `store_memberships` | Blocked (RESTRICTIVE) | `join_store` |
| `store_staff` | Blocked (RESTRICTIVE) | `approve_staff_applicant`, `demote_store_staff`, `admin_assign_staff`, `admin_remove_staff` |
| `store_managers` | Blocked (RESTRICTIVE) | `admin_assign_manager`, `admin_remove_manager` |
| `store_staff_applicants` | Blocked (RESTRICTIVE) | `apply_for_staff`, `approve_staff_applicant`, `admin_approve_applicant`, `admin_reject_applicant` |
| `points_ledger` | Blocked (RESTRICTIVE) | `award_points` |

### Admin identity

Admin RPCs check `is_admin()` — a `SECURITY DEFINER` helper that looks up `auth.uid()` in the `admins` table. To grant admin access, run `scripts/sql/assign-admin.sql` with the target user's public ID.

### XSS

All user-controlled values are escaped via `src/lib/escape.js` before being written to the DOM.

### Pre-RLS checklist

Before adding RLS to any table:

```sql
-- Check existing policies
SELECT tablename, policyname, cmd
FROM pg_policies
WHERE tablename = 'your_table';

-- Check if RLS is already enabled
SELECT relname, relrowsecurity
FROM pg_class
WHERE relname = 'your_table';
```

If RLS is off and there is no SELECT policy, add one (`USING (true)`) before enabling RLS or reads will break.

---

## SQL Scripts

All scripts in `scripts/sql/` — paste into Supabase Dashboard → SQL Editor and run.

| Script | What it does |
|---|---|
| `admin-rpcs.sql` | One-time setup: creates `admins` table, `is_admin()` helper, RESTRICTIVE RLS on `stores` and `store_reward_rules`, all admin RPCs. Safe to re-run. |
| `staff-rpcs.sql` | One-time setup: RESTRICTIVE RLS on `store_memberships`, `store_staff`, `store_staff_applicants`, `points_ledger`. Rewrites staff/manager RPCs as SECURITY DEFINER. Safe to re-run. |
| `assign-admin.sql` | Grants admin access to a user by their human-readable public ID. Run after reset or on a fresh project. |
| `delete-store.sql` | Deletes one store and all its memberships, staff, rules, and ledger entries. Set `v_store_id` at the top. |
| `delete-user.sql` | Deletes one user and all their data. Set `v_public_id` to their human-readable ID (shown in admin tool). |
| `delete-all-users.sql` | Deletes all users and their data (ledger, memberships, staff, profiles, auth). Leaves stores and reward rules intact. |
| `reset-all.sql` | Full wipe — every row in every table including stores, rules, and all auth users. No undo. |

Each script prints a row count per table so you can see exactly what was deleted.

---

## Fresh Setup / Reset Workflow

### First time (new Supabase project)

1. Run `scripts/sql/admin-rpcs.sql` in the SQL Editor
2. Run `scripts/sql/staff-rpcs.sql` in the SQL Editor
3. Open the admin tool locally: `http://localhost:5173/adminstart.html`
4. Your public ID is shown at the top of the page — copy it
5. Paste it into `scripts/sql/assign-admin.sql` and run it
6. Reload the admin tool — you now have admin access
7. Create stores, configure reward rules, assign managers

### After a full reset (`reset-all.sql`)

The RPC and RLS setup survives a reset — it lives in the database schema, not the data. Only steps 3–7 above are needed:

1. Open the admin tool — you'll get a new anonymous session with a new public ID
2. Copy your new public ID from the header
3. Run `assign-admin.sql` with the new public ID
4. Reload — admin access restored
5. Re-create stores and reward rules

---

## Commands

```bash
npm run dev
npm run build
npm run preview
npm run cleanup:preview
npm run cleanup:export
```
