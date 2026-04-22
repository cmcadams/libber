# Libber

Libber is a loyalty points app built with Vite and Supabase.

---

## Restructure Audit (2026-04-22)

Full import/export audit across all 24 source files — zero broken references found.

| Check | Result |
|---|---|
| All imports resolve to real files | ✓ |
| All named exports match imports | ✓ |
| All DOM element IDs referenced in JS exist in HTML | ✓ |
| All data attributes wired correctly | ✓ |
| State flows (localStorage → cross-page nav) | ✓ |

All 5 pages verified end-to-end: customer, staff apply, staff tools, manager, admin.

`adminstart.html` intentionally excluded from `vite.config.js` — local-only tool, not deployed.

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
- `adminstart.html` — create stores, configure reward rules (with ordering), assign managers

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
    admin.js          store creation, reward rules, admin_assign_manager
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

Deploy the `apps/customer/` output to one domain and `apps/staff/` output to another. The admin tool is never built for deployment — run it locally from dev only.

---

## Deployment Plan (two separate static sites)

- **Customer app** → e.g. `app.libber.com` — serve from `dist/apps/customer/`
- **Staff app** → e.g. `staff.libber.com` — serve from `dist/apps/staff/`
- Both can be deployed from the same repo via Netlify or Vercel using the build output directories above

---

## Auth Model

The app currently uses anonymous Supabase auth (`src/services/auth.js`):

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
2. Create stores
3. Configure reward rules per store (label, points, kind, ordering)
4. Assign managers to stores

---

## Points Model

Points are **not fungible across stores**. 50 pts at Store A cannot be combined with or used at Store B. Each store's balance is independent. Do not display a combined total.

---

## Reward Rules

Staff page buttons are driven by `store_reward_rules` in Supabase — not hardcoded. Configured per store in the admin tool.

- `kind = 'award'` — quick-award buttons (label + points, reason auto-set to label)
- `kind = 'redeem'` — bonus buttons (points only, staff enters reason manually)

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

## Supabase RPCs / Views

| Name | Auth check | What it does |
|---|---|---|
| `join_store` | `auth.uid()` required | Creates store membership for caller |
| `award_points` | Must be staff of the store | Inserts points ledger entry |
| `apply_for_staff` | `auth.uid()` required | Creates applicant record for caller |
| `approve_staff_applicant` | Must be manager of the store | Promotes applicant to staff, removes from applicants |
| `admin_assign_manager` | Must be admin (`admins` table) | Assigns a user as manager of a store |
| `admin_create_store` | Must be admin | Creates a store |
| `admin_update_store` | Must be admin | Renames a store |
| `admin_remove_store` | Must be admin | Deletes a store and all related data |
| `admin_insert_reward_rule` | Must be admin | Adds a reward rule to a store |
| `admin_delete_reward_rule` | Must be admin | Deletes a reward rule |
| `admin_update_reward_rule_order` | Must be admin | Updates sort order of a reward rule |
| `admin_assign_staff` | Must be admin | Directly assigns a user as staff |
| `admin_remove_staff` | Must be admin | Removes a user from store staff |
| `admin_remove_manager` | Must be admin | Removes a manager from a store |
| `admin_approve_applicant` | Must be admin | Approves a staff applicant |
| `admin_reject_applicant` | Must be admin | Rejects a staff applicant |
| `promote_store_staff` | Must be manager of the store | Promotes a store member to staff |
| `demote_store_staff` | Must be manager of the store | Removes a user from store staff |
| `admin_user_directory` | View | Lists all users (used by admin tool) |
| `staff_applicant_directory` | View | Lists applicants per store |
| `create_profile` | Trigger | Auto-creates a profile with public_id on new auth user |

---

## Security Status

### Done
- `award_points` — verifies caller is staff for the store
- `approve_staff_applicant` — verifies caller is manager for the store
- `apply_for_staff` — uses `auth.uid()`, enforces caller identity
- `admin_assign_manager` — restricted to service role only
- `points_ledger` direct INSERT blocked — only writable via RPC
- `points_ledger` SELECT restricted to own rows + staff of that store
- `store_staff` SELECT — open policy removed, manager-scoped policy added
- `store_staff_applicants` RLS enabled, policies added
- `profiles` SELECT restricted to own row
- Dead `renderStaff.js` (contained direct `points_ledger` insert) removed
- XSS — all user-controlled values escaped via shared `src/lib/escape.js` utility
- `stores` and `store_reward_rules` direct writes blocked — all admin writes go through RPCs (`admin_create_store`, `admin_update_store`, `admin_remove_store`, `admin_insert_reward_rule`, etc.)
- `store_staff` and `store_managers` direct writes blocked — all go through RPCs
- Admin identity enforced via `admins` table — `is_admin()` check inside every admin RPC

### Setup required (run once)
- Run `scripts/sql/admin-rpcs.sql` in the Supabase SQL Editor
- Then insert your user_id into the `admins` table: `INSERT INTO admins (user_id) VALUES ('your-auth-uid');`
- Find your user_id in Supabase Dashboard → Authentication → Users

### Still to do
- **Admin tool** — never deploy `adminstart.html`. Run locally only via `npm run dev`

---

## Safe Cleanup Workflow

Before deleting users or test data:

```bash
# Preview counts (non-destructive)
SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... npm run cleanup:preview

# Export backup JSON files
SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... npm run cleanup:export
```

Backups are written to a timestamped folder under `backups/cleanup-...`.

### SQL scripts (run in Supabase SQL Editor)

Three scripts in `scripts/sql/` — paste into Dashboard → SQL Editor and run.

| Script | What it does |
|---|---|
| `delete-store.sql` | Deletes one store and all its memberships, staff, rules, and ledger entries. Set `v_store_id` at the top. |
| `delete-user.sql` | Deletes one user and all their data across every table including `auth.users`. Set `v_user_id` at the top. |
| `delete-all-users.sql` | Deletes all users and their data (ledger, memberships, staff, profiles, auth). Leaves stores and reward rules intact. |
| `reset-all.sql` | Full wipe — every row in every table including all auth users. No undo. |

Each script prints a row count per table so you can see exactly what was deleted. `delete-store` and `delete-user` warn if the ID wasn't found.

---

## Commands

```bash
npm run dev
npm run build
npm run preview
npm run cleanup:preview
npm run cleanup:export
```
