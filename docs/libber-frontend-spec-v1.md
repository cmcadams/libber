# Libber Frontend Specification — v1

**Document type:** ACTIVE WORKING DOCUMENT  
**Last updated:** 2026-05-26  
**Update policy:** Update this document whenever a frontend page changes. Changes here do not require a migration, but must not require any backend change — if a change would touch the database, it belongs in `libber-backend-contract-v1.md` (locked) and requires a new migration.

---

## Scope

This document covers **frontend only**:

- Vanilla JS (Vite, no frameworks)
- HTML/CSS in `apps/` and repo root
- `src/pages/`, `src/services/`, `src/lib/`, `src/state/`

**Out of scope:** SQL, RLS policies, RPC logic, Supabase configuration, migrations. Any change to those belongs to the backend contract and requires an explicit migration.

**Critical safety rule:** If any frontend improvement would require a backend change to implement, document it in the `Future improvements requiring backend work` section of this file — do NOT implement it.

---

## Stack

| Layer | Technology |
|-------|-----------|
| Build tool | Vite |
| Language | Vanilla JS (ES modules) |
| Auth | Supabase anonymous auth (`initAuth()` in `src/services/auth.js`) |
| Database client | Supabase JS SDK (`src/lib/supabase.js`) |
| DOM helpers | `src/lib/dom.js` — `$()` (single), `$q()` (all) |
| Error tracking | Sentry (`src/lib/sentry.js`) |
| State | Module-level singleton (`src/state/state.js`) |

---

## Deployed applications

| App | Path | Deployment | Auth required |
|-----|------|-----------|---------------|
| Customer app | `apps/customer/` | `https://libber.pages.dev` | Anonymous auth (auto) |
| Staff awards app | `apps/staff/page.html` | `https://libber.pages.dev/apps/staff/page.html` | Anonymous auth + must be staff/manager at a store |
| Admin tool | `adminstart.html` (repo root) | **Local only — never deployed** | Must be in `admins` table |

---

## Security boundary rule

**The frontend is never the security boundary.**

All authorisation is enforced in PostgreSQL RPCs. The frontend may choose not to render a button for a permission the user doesn't have, but that is a UX convenience only — the corresponding RPC will reject the call if the user lacks permission. Never rely on frontend hiding to enforce security.

---

## Pages

---

### 1. Customer app (`apps/customer/`)

#### Purpose
The customer-facing loyalty points interface. Customers can view their balance, transaction history, join stores, and link their account.

#### Entry point
`apps/customer/index.html` → `src/pages/customer/main.js`

#### Auth flow
`initAuth()` → anonymous sign-in if no session → loads `load_customer_home` as the primary data bootstrap.

#### Realtime
Subscribes to `points_ledger` INSERT events filtered to `user_id = auth.uid()`. On event: **ignore `payload.new`** — call `load_customer_home` instead (the payload contains `created_by` which must not be consumed).

#### RPCs used

| RPC | Purpose |
|-----|---------|
| `load_customer_home(p_include_stores)` | Bootstrap: profile, memberships, balances, rules, history |
| `load_points_history(p_store_id)` | Store-specific full history (customer view) |
| `join_store(p_store_id)` | Self-service store join |
| `unjoin_store(p_store_id)` | Self-service store leave |
| `mark_account_linked()` | Record account link after OAuth |

#### Direct table reads

| Table/View | Columns | Purpose |
|-----------|---------|---------|
| `stores` | `id, name` | Store catalogue discovery |
| `profiles` | `user_id, public_id` | Own profile (own-row RLS) |

#### Save account flow
`apps/customer/save.html` — OAuth redirect landing. Calls `mark_account_linked()` on successful link.

---

### 2. Staff awards page (`apps/staff/page.html`)

#### Purpose
Primary operational interface for staff and managers. Award points, redeem points, adjust points, view member history, select outlet.

#### Entry point
`apps/staff/page.html` → `src/pages/staff/main.js`

#### Auth flow
`initAuth()` → `loadStaffStores()` (reads `store_staff` + `store_managers` directly) → user selects a store → app loads members and outlets for that store.

#### RPCs used

| RPC | Caller role | Purpose |
|-----|------------|---------|
| `load_store_members(p_store_id)` | Staff or manager | Load member list with balances |
| `load_store_outlets(p_store_id)` | Staff or manager | Load outlets for award form |
| `award_points(p_user_id, p_store_id, p_points, p_reason, p_rule_id, p_outlet_id)` | Staff or manager | Award or redeem points |
| `adjust_points(p_user_id, p_store_id, p_points, p_reason, p_outlet_id)` | Staff or manager | Manual correction (no rule required, no balance floor) |
| `load_member_recent_transactions(p_user_id, p_store_id)` | Staff or manager | Last 5 entries for selected member |
| `load_store_staff_profiles(p_store_id)` | Manager only | Staff roster (not rendered for non-managers) |
| `approve_staff_applicant(p_user_id, p_store_id)` | Manager only | Promote member to staff |
| `demote_store_staff(p_user_id, p_store_id)` | Manager only | Remove staff role |

#### Direct table reads

| Table | Columns | Purpose |
|-------|---------|---------|
| `store_staff` | `store_id, stores(name)` | Which stores the user is staff at |
| `store_managers` | `store_id, stores(name)` | Which stores the user manages |
| `store_reward_rules` | `id, label, points, kind, sort_order` | Rules for the award/redeem form |
| `stores` | `max_bonus_points` | Bonus cap display |

#### Semantic colour system

Section header colour communicates action type at a glance. Applied via CSS classes on `.section-label` elements.

| Class | Colour | Used for | CSS variables |
|-------|--------|----------|--------------|
| `.card-award` | Soft green | Award, Bonus | `--card-award-bg: rgba(75,155,50,0.11)` / `--card-award-text: #2d6a20` |
| `.card-adjust` | Soft amber | Adjust (corrections) | `--card-adjust-bg: rgba(200,140,0,0.13)` / `--card-adjust-text: #6b4800` |
| `.card-danger` | Soft red | Redeem, destructive actions | `--card-danger-bg: rgba(184,60,43,0.10)` / `--card-danger-text: #8b2213` |

**Section mapping:**
- `#quickSection` → `.card-award` (Quick award)
- `#bonusSection` → `.card-award` (Bonus)
- `#redeemSection` → `.card-danger` (Redeem)
- `#adjustSection` toggle → `.card-adjust` (Adjust)

#### Constraint: staff access to `adjust_points`
Staff (not just managers) must have access to the Adjust section. This is a product requirement. Do not gate `adjust_points` or the adjust UI on manager role.

---

### 3. Admin store management (`adminstart.html`)

#### Purpose
Admin-only local tool for full store management. Never deployed. Runs only at `localhost:5173/adminstart.html` (or equivalent Vite dev port).

#### Entry point
`adminstart.html` → `src/pages/admin/start.js`

#### Auth flow
`initAuth()` → `supabase.rpc('is_admin')` → if not admin, show error and halt. No fallback, no redirect.

#### Two-view navigation

| View element | State | Description |
|-------------|-------|-------------|
| `#viewStores` | Landing (default) | Store grid — all stores as clickable cards |
| `#viewStore` | Detail | Single store — all management sections |

Navigation is toggled by adding/removing `.hidden` class. `showStoreList()` → `#viewStores` visible. `showStoreDetail(storeId, storeName)` → `#viewStore` visible.

#### Race guard
`loadSeq` counter prevents stale renders when switching between stores quickly. Each `showStoreDetail` call increments `loadSeq`; async callbacks check their captured sequence matches current before rendering.

#### State variables

```js
let allStores = []          // all stores from admin_user_directory + stores table
let allUsers  = []          // full user directory from admin_user_directory
let currentStoreId   = null
let currentStoreName = null
let loadSeq  = 0
let rulesLocal   = []       // reward rules for current store (local copy for re-render)
let outletsLocal = []       // outlets for current store (local copy for re-render)
```

#### People sections — de-duplication logic
A user can appear in multiple role tables (`store_managers`, `store_staff`, `store_memberships`). Sections are rendered with Set-based filtering:

```
managers   = all rows from store_managers for this store
staff      = all rows from store_staff for this store
members    = all rows from store_memberships for this store
pureStaff  = staff where user_id ∉ managers
pureMembers = members where user_id ∉ managers AND user_id ∉ staff
```

Each person appears in exactly one section: their highest-privilege section.

#### `personRow(userId, actionEls)` helper
Renders a person row with public ID and UUID:

```js
function personRow(userId, actionEls) {
  const u   = allUsers.find(u => u.user_id === userId)
  const pid = escapeHtml(u?.public_id || '—')   // display name
  const uid = escapeHtml(userId)                  // UUID always shown
  return `<div class="dir-row">
    <div class="dir-info">
      <span class="dir-name">${pid}</span>
      <span class="dir-sub">${uid}</span>
    </div>
    <div class="dir-actions">${actionEls.join('')}</div>
  </div>`
}
```

#### `confirmStep(btn, originalLabel, ms)` utility
Double-confirm pattern for destructive actions. First click: button text → "Sure?" and sets `data-confirm="true"`. Second click within `ms` (default 3000): proceeds. Timeout: button resets to original label.

#### RPCs used

| RPC | Purpose |
|-----|---------|
| `is_admin()` | Auth gate check on load |
| `admin_create_store(p_name)` | Create store |
| `admin_update_store(p_store_id, p_name)` | Rename store |
| `admin_remove_store(p_store_id)` | Cascade delete entire store |
| `admin_archive_store(p_store_id)` | Soft-delete (archive) store |
| `admin_restore_store(p_store_id)` | Restore archived store |
| `admin_set_bonus_cap(p_store_id, p_max_bonus_points)` | Set/clear bonus cap |
| `admin_set_store_logo(p_store_id, p_logo_path)` | Update logo path after upload |
| `admin_insert_reward_rule(p_store_id, p_label, p_points, p_kind, p_sort_order)` | Add reward rule |
| `admin_delete_reward_rule(p_id)` | Delete reward rule |
| `admin_update_reward_rule_order(p_id, p_sort_order)` | Update rule display order |
| `admin_create_outlet(p_store_id, p_name)` | Add outlet |
| `admin_update_outlet(p_outlet_id, p_name)` | Rename outlet |
| `admin_delete_outlet(p_outlet_id)` | Delete outlet |
| `admin_assign_staff(p_user_id, p_store_id)` | Grant staff role (admin-level, bypasses membership check) |
| `admin_remove_staff(p_user_id, p_store_id)` | Remove staff role |
| `admin_assign_manager(p_user_id, p_store_id)` | Grant manager role |
| `admin_remove_manager(p_user_id, p_store_id)` | Remove manager role |
| `admin_load_store_members(p_store_id)` | Load all member UUIDs for a store |

#### Direct table / view reads

| Table/View | Columns | Purpose |
|-----------|---------|---------|
| `admin_user_directory` | `user_id, public_id` | Full user directory (admin RLS) |
| `stores` | `id, name, logo_path, logo_updated_at, is_active, deleted_at` | Store list |
| `store_managers` | `user_id` | Managers of current store |
| `store_staff` | `user_id` | Staff of current store |
| `store_reward_rules` | `id, label, points, kind, sort_order` | Rules for current store |

#### Storage
Logo uploads go to Supabase Storage bucket `store-logos` at path `stores/{store_id}/logo.webp` via `uploadStoreLogo()` in `src/services/admin.js`. After upload, `admin_set_store_logo` is called to record the path.

---

## UI system rules

### Design tokens (shared across all pages)

```css
--bg:      #f5f5f5
--surface: #ffffff
--border:  #e0e0e0
--accent:  #1a73e8
--danger:  #b83c2b
--radius:  8px
--mono:    'JetBrains Mono', monospace
--ui:      system-ui, sans-serif
```

### Semantic section colours (staff page only)

```css
--card-award-bg:   rgba(75, 155, 50,  0.11)
--card-award-text: #2d6a20
--card-adjust-bg:  rgba(200, 140, 0,  0.13)
--card-adjust-text:#6b4800
--card-danger-bg:  rgba(184, 60,  43, 0.10)
--card-danger-text:#8b2213
```

Classes `.card-award`, `.card-adjust`, `.card-danger` are `display: inline-block; padding: 2px 8px; border-radius: 4px; font-weight: 600;`

### Admin-specific CSS patterns

| Class | Purpose |
|-------|---------|
| `.view` | Full-height section; default visible |
| `.view.hidden` | Hidden via `display: none` |
| `.store-grid` | Responsive CSS grid for store cards |
| `.store-card` | Clickable store card with hover/active states |
| `.badge-active` / `.badge-archived` | Status pill on store cards |
| `.back-nav` / `.back-btn` | Back navigation header |
| `.store-header-card` | Store name + logo + controls at top of detail |
| `.store-detail-layout` | Two-column grid for detail sections |
| `.detail-section` | Section wrapper with border |
| `.section-header` | Section title row |
| `.dir-row` | Person row: `dir-info` (name + sub) + `dir-actions` |
| `.dir-name` | Public ID (pid) |
| `.dir-sub` | UUID in monospace |

---

## DOM helper usage

`src/lib/dom.js` exports:
- `$(selector, context?)` — `querySelector` wrapper (returns first match)
- `$q(selector, context?)` — `querySelectorAll` wrapper (returns NodeList)

Use these rather than bare `document.querySelector` calls. Do not import `$q` if it isn't used in the file — ESLint will flag it.

---

## Event binding patterns

### Section-level delegation (bound once in `bindEvents()`)
For sections that persist across store loads (e.g. `#sectionManagers`, `#sectionStaff`, `#sectionMembers`), bind click listeners via delegation on the section container. These survive innerHTML replacement of child content.

### Re-bind after innerHTML replacement
For elements whose innerHTML is fully replaced on each data load (`#storeHeader`, reward forms, outlet forms), re-bind event listeners inside the render function immediately after the innerHTML assignment.

---

## Allowed direct table reads (client-side)

The following tables are permitted for direct client queries (authenticated role has SELECT grant per migration 20):

1. `stores` — open SELECT, all columns
2. `store_staff` — SELECT scoped by RLS to self, manager of same store, or admin
3. `store_managers` — SELECT scoped by RLS to self or admin
4. `store_reward_rules` — open SELECT
5. `profiles` — SELECT scoped by RLS to self or admin
6. `points_ledger` — SELECT scoped by RLS to own rows; used for Realtime subscription only

Do not add direct table reads for any other table without first confirming migration 20 has been updated to include the corresponding SELECT grant.

---

## Future improvements requiring backend work

These are valid ideas that cannot be implemented frontend-only. Do not implement without a new migration and update to `libber-backend-contract-v1.md`:

- Show `created_by` (staff name) on customer transaction history — requires `created_by` to be returned by a read RPC (currently excluded from all outputs).
- Paginated member list — requires `p_offset` / `p_limit` parameters on `load_store_members` and `admin_load_store_members`.
- Customer-visible store rules with IDs — requires `id` column added to `load_customer_home` rule output.
- Staff roster visible to all staff (not just managers) — requires adding `store_staff` to the auth check in `load_store_staff_profiles`.
- Configurable transaction history length — requires a `p_limit` parameter on `load_member_recent_transactions`.
- Idempotent point awards — requires an `idempotency_key` column on `points_ledger`.
