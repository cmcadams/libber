# Libber

Libber is a small multi-surface loyalty app prototype built with Vite and Supabase.

Right now the project is organized around three user-facing surfaces on the same site:

- `customer`: joins stores and views points
- `staff`: applies for staff access, then awards points after approval
- `manager`: reviews staff applicants and promotes them

There is also a temporary `admin` surface used to assign managers to stores during setup.

## Current Pages

- `index.html`
  Customer surface. Shows the current user's ID, joined stores, balances, and available stores to join.

- `staffstart.html`
  Staff onboarding surface. A user picks a store and applies for staff access.

- `managerstart.html`
  Manager onboarding/approval surface. A manager sees their stores and approves staff applicants.

- `staffpage.html`
  Existing staff operations surface. Used to load members for a selected store and award points.

- `adminstart.html`
  Temporary admin setup surface. Lets you assign a user as manager for a store.

## Project Structure

```text
src/
  lib/
    storage.js
    supabase.js
  pages/
    admin/
      start.js
    manager/
      start.js
    staff/
      start.js
  services/
    admin.js
    applicants.js
    auth.js
    members.js
    staff.js
    stores.js
  state/
    state.js
  ui/
    renderCustomers.js
    renderStaff.js
    renderStores.js
    renderUser.js
  main.js
  staffMain.js
```

## Stack

- Vite
- Vanilla JavaScript
- Supabase (`@supabase/supabase-js`)

## Local Setup

1. Install dependencies:

```bash
npm install
```

2. Create environment variables for Vite:

```bash
VITE_SUPABASE_URL=your_supabase_project_url
VITE_SUPABASE_ANON_KEY=your_supabase_anon_key
```

These are required by [src/lib/supabase.js](/home/cormac/Documents/code/first/libber/src/lib/supabase.js:1).

3. Start the dev server:

```bash
npm run dev
```

4. Open the pages you want to test in the browser:

- `/`
- `/adminstart.html`
- `/staffstart.html`
- `/managerstart.html`
- `/staffpage.html`

## Important Build Note

`npm run build` currently succeeds, but the project is still effectively using Vite as a single-page build. Extra HTML entrypoints exist and work well in local/dev usage, but they are not yet configured as a full multi-page production build.

For now, treat this repo as a local prototype first.

## Auth Model Right Now

The app currently uses anonymous Supabase auth through [src/services/auth.js](/home/cormac/Documents/code/first/libber/src/services/auth.js:1).

That means:

- a visitor gets or restores an anonymous Supabase user
- all role assignment is tied to that current Supabase `auth.uid()`
- because all current surfaces are on one site, that shared anonymous identity is workable for prototype use

Long term, staff and manager flows should move to real sign-in such as Google, magic link, or email auth.

## Current Product Flow

### Customer

1. Open `index.html`
2. Anonymous auth is initialized
3. User profile is loaded from Supabase
4. Joined stores and balances are loaded
5. User can join additional stores

### Staff Applicant

1. Open `staffstart.html`
2. Anonymous auth is initialized
3. Pick a store
4. Click `Apply for staff`
5. This creates an applicant record for that user/store

### Manager

1. Open `managerstart.html`
2. Anonymous auth is initialized
3. Managed stores are loaded
4. Pick a store
5. Review applicants
6. Approve an applicant to promote them to staff

### Staff

1. Open `staffpage.html`
2. Auth is initialized
3. Selected store is loaded from local storage
4. Store members are loaded
5. Staff can award points

### Admin

1. Open `adminstart.html`
2. Anonymous auth is initialized
3. Browse all users and all stores
4. Assign a user as manager for a store

## Supabase Concepts In Use

Based on the current repo and SQL work so far, the app relies on these main database concepts:

- `profiles`
- `stores`
- `store_memberships`
- `store_staff`
- `store_managers`
- `store_staff_applicants`
- `points_ledger`

Known RPCs/views used by the frontend:

- `join_store`
- `award_points`
- `admin_assign_manager`
- `apply_for_staff`
- `approve_staff_applicant`
- `admin_user_directory`
- `staff_applicant_directory`

## Frontend Entry Logic

### Customer

- [src/main.js](/home/cormac/Documents/code/first/libber/src/main.js:1)

### Staff Apply

- [src/pages/staff/start.js](/home/cormac/Documents/code/first/libber/src/pages/staff/start.js:1)

### Manager Approvals

- [src/pages/manager/start.js](/home/cormac/Documents/code/first/libber/src/pages/manager/start.js:1)

### Admin Manager Assignment

- [src/pages/admin/start.js](/home/cormac/Documents/code/first/libber/src/pages/admin/start.js:1)

### Existing Staff Operations

- [src/staffMain.js](/home/cormac/Documents/code/first/libber/src/staffMain.js:1)

## Service Layer

- [src/services/auth.js](/home/cormac/Documents/code/first/libber/src/services/auth.js:1)
  Handles anonymous auth bootstrap and stores the current user in shared state.

- [src/services/stores.js](/home/cormac/Documents/code/first/libber/src/services/stores.js:1)
  Loads stores and handles store joining.

- [src/services/members.js](/home/cormac/Documents/code/first/libber/src/services/members.js:1)
  Loads customer balances, profiles, members, and calls `award_points`.

- [src/services/admin.js](/home/cormac/Documents/code/first/libber/src/services/admin.js:1)
  Loads admin-facing users and stores, and calls `admin_assign_manager`.

- [src/services/applicants.js](/home/cormac/Documents/code/first/libber/src/services/applicants.js:1)
  Handles staff applications, manager store loading, applicant loading, and applicant approval.

## Shared State

Shared in-memory state lives in [src/state/state.js](/home/cormac/Documents/code/first/libber/src/state/state.js:1).

It currently tracks values such as:

- `user`
- `stores`
- `userStores`
- `staffStores`
- `selectedStoreId`
- `selectedStoreName`
- `members`

This state is simple and mutable on purpose for the prototype.

## Known Limitations

- Role/security rules are still prototype-oriented in places
- Some Supabase RPCs are intentionally permissive for local testing
- Multi-page production build config is not set up yet
- Some older files remain in the repo while the product direction is still settling

## Recommended Next Steps

1. Add proper authorization checks around staff and manager RPCs.
2. Decide whether to keep or remove the old prototype admin/staff pages.
3. Add multi-page Vite build configuration if these separate HTML files will ship.
4. Move staff and manager flows from anonymous auth to real sign-in when ready.
5. Add tests or at least a repeatable Supabase seed/setup document.

## Commands

```bash
npm run dev
npm run build
npm run preview
```

## Safe Cleanup Workflow

Before deleting users or test data, use these scripts:

1. Preview current counts (non-destructive):

```bash
SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... npm run cleanup:preview
```

2. Export backup JSON files:

```bash
SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... npm run cleanup:export
```

Backups are written to a timestamped folder under `backups/cleanup-...`.

## Status

This repo is currently best understood as an actively evolving local prototype. The main shape is now:

- customer joins stores
- staff applicant applies from the staff start page
- manager approves applicants
- staff uses the staff tools
- admin assigns managers
