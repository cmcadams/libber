# Database Security Contract

**Document Version:** 1.2
**Last Updated:** 2026-05-01
**Status:** Living document — update whenever an RPC, table, or RLS policy changes.

---

## Update History

| Version | Date | Change |
|---------|------|--------|
| 1.0 | 2026-04-28 | Initial hardening: SECURITY DEFINER RPCs, RESTRICTIVE write blocks, anon grant revoke |
| 1.1 | 2026-04-29 | award_points: advisory lock, redemption rule validation, negative balance floor. admin_user_directory: security_invoker view + admin profile policy |
| 1.2 | 2026-05-01 | approve_staff_applicant: store-membership guard added post-applicant-system removal. load_member_recent_transactions: new staff RPC. Applicant tables and RPCs dropped. |

---

## Core Security Model

All write operations and all cross-user read operations go through **SECURITY DEFINER RPCs**. Direct client queries against `points_ledger`, `store_staff`, or `profiles` are disallowed for cross-user data — RLS blocks what RPC auth doesn't.

```
Client (anon key)
  │
  ├─ Direct table query → RLS enforced at caller identity
  │    ✓ OK for own-row reads (ledger Realtime, own profile)
  │    ✗ Never for cross-user data (staff reading customer rows)
  │
  └─ supabase.rpc() → SECURITY DEFINER function
       Auth checked inside function body via auth.uid()
       RLS bypassed — function runs as DB owner
       Store scoping enforced explicitly in function logic
```

Three identity roles in play:

| Role | How granted | Access |
|------|------------|--------|
| `anon` | No auth session | No table privileges, no RPC execute |
| `authenticated` | Any Supabase auth session (including anonymous) | RPC execute only; table reads scoped by RLS |
| `service_role` | Server-side only, never in browser | Full bypass — `admins` table management only |

---

## Section 1: Tables & RLS Policies

### `admins`

**Purpose:** Tracks which user IDs have admin privileges. Queried by `is_admin()`.

| Column | Type | Notes |
|--------|------|-------|
| `user_id` | `uuid` PK | References `auth.users(id) ON DELETE CASCADE` |
| `created_at` | `timestamptz` | Default `now()` |

**RLS policies:**

| Operation | Policy | Expression |
|-----------|--------|------------|
| ALL | `admins: service role only` | `auth.role() = 'service_role'` |

**Why:** Admin rows must never be readable or writable by authenticated clients. The only way to grant admin status is via the Supabase dashboard SQL editor or a service-role migration. `is_admin()` uses `SECURITY DEFINER` to read this table, so the RLS block never interferes with legitimate checks.

**Invariants:**
- `INV-ADMINS-001` — No authenticated client can SELECT, INSERT, UPDATE, or DELETE any row in this table.
- `INV-ADMINS-002` — A user must be manually inserted into this table via the SQL editor before any admin RPC will accept their requests.

**Maintenance checklist:**
- [ ] If `auth.users` schema changes, verify `ON DELETE CASCADE` still resolves correctly.
- [ ] If `is_admin()` is replaced with a different mechanism, update this table's policy to match.
- [ ] Never add a permissive SELECT policy to this table for any role below `service_role`.

---

### `stores`

**Purpose:** Master list of stores. Read by all authenticated users for store discovery.

| Column | Type | Notes |
|--------|------|-------|
| `id` | `uuid` PK | |
| `name` | `text` | Trimmed on insert/update via RPC |
| `max_bonus_points` | `integer` | Nullable — `NULL` means no cap |

**RLS policies:**

| Operation | Policy | Expression |
|-----------|--------|------------|
| SELECT | `stores: allow select` | `true` |
| INSERT | `stores: no direct insert` (**RESTRICTIVE**) | `false` |
| UPDATE | `stores: no direct update` (**RESTRICTIVE**) | `false` |
| DELETE | `stores: no direct delete` (**RESTRICTIVE**) | `false` |

**Why:** Stores are non-sensitive (names are public). All mutations go through `admin_create_store`, `admin_update_store`, `admin_remove_store`, which enforce `is_admin()` server-side.

**Invariants:**
- `INV-STORES-001` — No authenticated client can write to this table directly. The RESTRICTIVE policies override any future accidental permissive policy.
- `INV-STORES-002` — `max_bonus_points`, when non-null, must be ≥ 1 (enforced in `admin_set_bonus_cap`).

**Maintenance checklist:**
- [ ] If a new column is added that should be writable, add or update the relevant admin RPC rather than relaxing the RESTRICTIVE write block.
- [ ] If `max_bonus_points` gains a DB CHECK constraint, update `admin_set_bonus_cap` to remove the redundant application-level check, or keep both for defence in depth.

---

### `store_reward_rules`

**Purpose:** Configures award, redeem, and bonus rules per store. Read by customers and staff.

| Column | Type | Notes |
|--------|------|-------|
| `id` | `uuid` PK | |
| `store_id` | `uuid` | FK → `stores(id)` |
| `label` | `text` | Display name |
| `points` | `integer` | Positive for award/redeem/bonus_amount; 0 for bonus_reason |
| `kind` | `text` | CHECK: `award`, `redeem`, `bonus_reason`, `bonus_amount` |
| `sort_order` | `integer` | Display order |
| `is_active` | `boolean` | Only active rules are shown to staff/customers |
| `is_pinned` | `boolean` | Reserved for future UI pinning |

**RLS policies:**

| Operation | Policy | Expression |
|-----------|--------|------------|
| SELECT | `rules: allow select` | `true` |
| INSERT | `rules: no direct insert` (**RESTRICTIVE**) | `false` |
| UPDATE | `rules: no direct update` (**RESTRICTIVE**) | `false` |
| DELETE | `rules: no direct delete` (**RESTRICTIVE**) | `false` |

**Why:** Rule definitions are not sensitive (they're shown to customers on the "how to earn" screen). All mutations are admin-only via RPCs. The RESTRICTIVE write block ensures no client can forge or delete rules regardless of any future RLS mistake.

**Invariants:**
- `INV-RULES-001` — `kind` must be one of the four allowed values (enforced by DB CHECK constraint).
- `INV-RULES-002` — `award_points` validates that a supplied `p_rule_id` matches `kind`, `store_id`, `is_active`, and `points` before writing a ledger entry. A rule that exists but fails any of these checks will cause the RPC to raise.
- `INV-RULES-003` — `bonus_reason` rules always have `points = 0` (set by the admin UI before insertion).

**Maintenance checklist:**
- [ ] If a new `kind` value is added, update the DB CHECK constraint AND the frontend `KIND_LABEL` mapping in `src/pages/admin/start.js`.
- [ ] If rules become updatable (e.g. label edit), add an `admin_update_reward_rule` RPC rather than relaxing the RESTRICTIVE UPDATE block.
- [ ] If `is_active` should be toggled without deleting, add a dedicated `admin_toggle_reward_rule` RPC.

---

### `store_memberships`

**Purpose:** Tracks which users have joined which stores. Required before a user can earn points or be made staff.

| Column | Type | Notes |
|--------|------|-------|
| `user_id` | `uuid` | FK → `auth.users(id)` |
| `store_id` | `uuid` | FK → `stores(id)` |
| `created_at` | `timestamptz` | |

Primary key: `(user_id, store_id)`.

**RLS policies:**

| Operation | Policy | Expression |
|-----------|--------|------------|
| SELECT | `memberships: select own` | `user_id = auth.uid()` |
| INSERT | `memberships: no direct insert` (**RESTRICTIVE**) | `false` |

**Why:** Users may only see their own memberships (privacy). Only `join_store` (SECURITY DEFINER) inserts rows, ensuring `user_id` is always the caller's `auth.uid()` — a client cannot insert a membership on behalf of another user.

**Invariants:**
- `INV-MEMB-001` — A user can only be joined to a store as themselves; `join_store` anchors `user_id = auth.uid()`.
- `INV-MEMB-002` — `approve_staff_applicant` requires a matching row in this table before inserting into `store_staff`. A user cannot be made staff at a store they have not joined.

**Maintenance checklist:**
- [ ] If memberships become removable (leave store), add an RPC that deletes from `store_memberships`, `store_staff`, and cascades balance handling as needed. Do not add a DELETE policy directly.
- [ ] If `approve_staff_applicant` changes its membership check, verify `INV-MEMB-002` still holds.

---

### `store_staff`

**Purpose:** Tracks which users have the staff role at which stores.

| Column | Type | Notes |
|--------|------|-------|
| `user_id` | `uuid` | FK → `auth.users(id)` |
| `store_id` | `uuid` | FK → `stores(id)` |
| `created_at` | `timestamptz` | |

Primary key: `(user_id, store_id)`.

**RLS policies:**

| Operation | Policy | Expression |
|-----------|--------|------------|
| SELECT | `staff: select self` | `user_id = auth.uid()` |
| SELECT | `staff: select as manager` | `EXISTS (SELECT 1 FROM store_managers WHERE store_id = store_staff.store_id AND user_id = auth.uid())` |
| SELECT | `staff: select as admin` | `public.is_admin()` |
| INSERT | `staff: no direct insert` (**RESTRICTIVE**) | `false` |
| DELETE | `staff: no direct delete` (**RESTRICTIVE**) | `false` |

**Why:** Staff identity is sensitive — a user should not be able to discover all staff at a store they don't manage. Three permissive policies (OR-ed by PostgreSQL) cover the legitimate read cases. RESTRICTIVE write blocks ensure insertions and deletions only happen through `admin_assign_staff`, `admin_remove_staff`, `approve_staff_applicant`, and `demote_store_staff`.

**Invariants:**
- `INV-STAFF-001` — A row in `store_staff` implies the user also has a row in `store_memberships` for the same `(user_id, store_id)` pair. This is enforced by `approve_staff_applicant`; direct admin assignment via `admin_assign_staff` does not enforce this (admin bypass).
- `INV-STAFF-002` — A manager can only demote staff at stores where the manager has a row in `store_managers`. Cross-store demotion is blocked server-side in `demote_store_staff`.

**Maintenance checklist:**
- [ ] If a new role (e.g. `supervisor`) is added, evaluate whether it should have read access to `store_staff` rows and add a corresponding policy.
- [ ] If `award_points` or `adjust_points` auth checks change from a UNION of `store_staff` + `store_managers`, update this document and the corresponding RPC entry.

---

### `store_managers`

**Purpose:** Tracks which users have the manager role at which stores. Managers have elevated privileges over staff.

| Column | Type | Notes |
|--------|------|-------|
| `user_id` | `uuid` | FK → `auth.users(id)` |
| `store_id` | `uuid` | FK → `stores(id)` |

Primary key: `(user_id, store_id)`.

**RLS policies:**

| Operation | Policy | Expression |
|-----------|--------|------------|
| SELECT | `managers: allow select` | `user_id = auth.uid() OR public.is_admin()` |
| INSERT | `managers: no direct insert` (**RESTRICTIVE**) | `false` |
| DELETE | `managers: no direct delete` (**RESTRICTIVE**) | `false` |

**Why:** Managers can only see their own manager records (to discover which stores they manage). Admins see all. No client writes are permitted; only `admin_assign_manager` and `admin_remove_manager` modify this table.

**Invariants:**
- `INV-MGR-001` — Only an admin can assign or remove a manager. There is no manager-self-promotion path.
- `INV-MGR-002` — `load_store_staff_profiles`, `approve_staff_applicant`, and `demote_store_staff` all gate on a matching row in this table for the caller.

**Maintenance checklist:**
- [ ] If managers should be able to view other managers at their store, add a `managers: select as manager` policy mirroring the `store_staff` pattern.
- [ ] If manager grants become self-service, the entire grant flow must still go through an RPC that validates the granting authority.

---

### `profiles`

**Purpose:** Maps `auth.users` UUIDs to human-readable public IDs shown in the UI.

| Column | Type | Notes |
|--------|------|-------|
| `user_id` | `uuid` PK | FK → `auth.users(id)` |
| `public_id` | `text` | Display-safe identifier |

**RLS policies:**

| Operation | Policy | Expression |
|-----------|--------|------------|
| SELECT | `profiles: select own` | `auth.uid() = user_id` |
| SELECT | `profiles: select as admin` | `public.is_admin()` |

**Why:** `public_id` is display-safe but still personally identifying. Users see only their own profile via direct query. Admins see all (for the user directory). SECURITY DEFINER RPCs (`load_store_members`, `load_store_staff_profiles`, `load_customer_home`) bypass RLS entirely and return `public_id` values to authorised staff/managers.

**Views:**
- `admin_user_directory` — `security_invoker = true` view over `profiles` ordered by `public_id`. Respects the caller's RLS context: admins see all rows, non-admins see only their own. `anon` access revoked.

**Invariants:**
- `INV-PROF-001` — No client can read another user's `public_id` via direct table query unless they are an admin.
- `INV-PROF-002` — SECURITY DEFINER RPCs may return `public_id` to staff/managers as part of aggregated member lists, but they never expose `auth.users` email or phone fields.

**Maintenance checklist:**
- [ ] If new sensitive columns are added to `profiles`, verify the SECURITY DEFINER RPCs do not include them in their SELECT lists.
- [ ] If `admin_user_directory` is modified, confirm `security_invoker = true` is preserved.

---

### `points_ledger`

**Purpose:** Append-only log of all point transactions. `running_balance` is the canonical balance for a user at a store.

| Column | Type | Notes |
|--------|------|-------|
| `user_id` | `uuid` | FK → `auth.users(id)` |
| `store_id` | `uuid` | FK → `stores(id)` |
| `points` | `integer` | Positive = award; negative = redemption or deduction |
| `reason` | `text` | Human-readable label or rule name |
| `created_by` | `uuid` | Staff/manager `auth.uid()` at time of write |
| `running_balance` | `integer` | Balance after this entry — computed inside the RPC, not by the client |
| `created_at` | `timestamptz` | Default `now()` |

**RLS policies:**

| Operation | Policy | Expression |
|-----------|--------|------------|
| SELECT | `ledger: select own` | `user_id = auth.uid()` |
| INSERT | `ledger: no direct insert` (**RESTRICTIVE**) | `false` |

**Why:** Customers may read their own ledger directly (used for Realtime subscription). No client — including authenticated staff — may query another user's rows directly. Cross-user reads go through `load_store_members` (balance only) or `load_member_recent_transactions` (last 5 entries), both of which enforce store-scoped auth server-side.

**Invariants:**
- `INV-LEDGER-001` — `running_balance` is always computed inside `award_points` or `adjust_points` as `previous_running_balance + p_points`. The client never sends a balance value.
- `INV-LEDGER-002` — `award_points` enforces `running_balance >= 0` before inserting. `adjust_points` does not (intentional staff-correction bypass).
- `INV-LEDGER-003` — `created_by` is always `auth.uid()` of the calling staff/manager, recorded inside the RPC. The client cannot forge this value.
- `INV-LEDGER-004` — No UPDATE or DELETE policy exists. The ledger is strictly append-only. Historical rows cannot be modified through any authenticated path.

**Maintenance checklist:**
- [ ] If a soft-delete or void mechanism is added, implement it as a compensating negative entry (append-only integrity preserved), not as a DELETE.
- [ ] If `running_balance` computation is moved to a trigger, remove the in-RPC computation and update `INV-LEDGER-001`.
- [ ] Any new RPC that reads cross-user ledger data must enforce staff/manager store scoping; direct client queries remain disallowed.

---

## Section 2: RPCs

### Naming convention

All parameters use the `p_` prefix. All functions use `SECURITY DEFINER` and `SET search_path = ''` unless noted.

---

### `is_admin()`

| Attribute | Value |
|-----------|-------|
| Returns | `boolean` |
| Language | `sql` |
| Volatility | `STABLE` |
| Auth gate | `auth.uid()` checked inside |

**What it does:** Checks whether the calling user has a row in `admins`. Used as the gate for all `admin_*` RPCs.

**Why STABLE:** Safe for PostgreSQL to cache within a single query. Avoids repeated hits to `admins` when called multiple times in one transaction.

**Invariant:** `INV-ISADMIN-001` — This function is the single source of admin truth. Do not inline the `SELECT EXISTS ... FROM admins` check in new RPCs; always call `is_admin()`.

---

### `award_points(p_user_id, p_store_id, p_points, p_reason, p_rule_id)`

| Attribute | Value |
|-----------|-------|
| Returns | `integer` (new balance) |
| Auth gate | Staff OR manager of `p_store_id` |
| Tables written | `points_ledger` |
| Tables read | `store_staff`, `store_managers`, `store_reward_rules`, `points_ledger`, `stores` |

**Auth flow:**

```
1. auth.uid() IS NULL → raise 'not authenticated'
2. caller ∉ store_staff ∪ store_managers for p_store_id → raise 'not authorized'
3. pg_advisory_xact_lock(hashtext(p_user_id), hashtext(p_store_id))   ← serialise concurrent calls
4. p_points = 0 → raise 'points cannot be zero'
5a. p_points > 0, p_rule_id provided → validate rule (store_id, is_active, kind='award', points match)
5b. p_points > 0, no p_rule_id → check store max_bonus_points cap
5c. p_points < 0, no p_rule_id → raise 'redemptions must reference a reward rule'
5d. p_points < 0, p_rule_id provided → validate rule (store_id, is_active, kind='redeem', points = -p_points)
6. Read current running_balance from points_ledger
7. new_balance < 0 → raise 'insufficient points'
8. INSERT into points_ledger
```

**Why the advisory lock:** PostgreSQL READ COMMITTED isolation means two concurrent calls can both read the same `running_balance` before either writes. The lock serialises access per `(user_id, store_id)` pair at the transaction level, preventing a race that could produce a negative balance even when the `new_balance < 0` guard is present.

**Output constraints:** Returns the new integer balance. No JSON wrapping.

**Invariants:**
- `INV-AWARD-001` — Redemptions (negative points) always require a valid `p_rule_id`. Free-form deductions are not permitted via this function.
- `INV-AWARD-002` — Balance can never go below 0 through this function.
- `INV-AWARD-003` — Rule validation checks `store_id`, `is_active`, `kind`, and exact `points` value — partial matches are rejected.

**Maintenance checklist:**
- [ ] If `store_reward_rules.kind` gains new values that can be used as redemptions, update the redemption branch check.
- [ ] If the balance floor should apply to `adjust_points` too, add the guard there separately.
- [ ] If the `points_ledger` schema changes (e.g. column rename), update the INSERT and SELECT inside this function.

---

### `adjust_points(p_user_id, p_store_id, p_points, p_reason)`

| Attribute | Value |
|-----------|-------|
| Returns | `integer` (new balance) |
| Auth gate | Staff OR manager of `p_store_id` |
| Tables written | `points_ledger` |
| Tables read | `store_staff`, `store_managers`, `points_ledger` |

**What it does:** Manual correction path for staff. Bypasses rule validation and the bonus cap. Intentionally has no negative balance floor — a staff correction may need to set a balance to zero or negative in an error-recovery scenario.

**No advisory lock:** The concurrent race risk is accepted for this function. Two simultaneous staff corrections on the same customer are operationally implausible; if it occurs, the discrepancy is visible in the ledger log and correctable with a follow-up entry.

**Invariants:**
- `INV-ADJ-001` — `p_points = 0` is rejected. A zero adjustment has no effect and is likely a UI bug.
- `INV-ADJ-002` — No rule validation occurs. This is the explicit, auditable bypass for corrections that don't match any configured rule.

**Maintenance checklist:**
- [ ] If negative balances become operationally unacceptable, add the `INV-LEDGER-002` guard from `award_points` to this function.
- [ ] If an audit trail beyond `created_by` is required (e.g. a reason category), add a `p_category` parameter rather than overloading `p_reason`.

---

### `load_store_members(p_store_id)`

| Attribute | Value |
|-----------|-------|
| Returns | `json` (array of `{user_id, public_id, balance}`) |
| Auth gate | Staff OR manager of `p_store_id` |
| Tables read | `store_staff`, `store_managers`, `store_memberships`, `profiles`, `points_ledger` |

**What it does:** Returns the full member list for a store including current balance. Used to populate the staff panel member list. Balance is read from the most recent `running_balance` in `points_ledger`.

**Why SECURITY DEFINER:** `profiles` RLS restricts reads to own-row. This function must read `public_id` for all members, which requires bypassing RLS.

**Cross-reference:** `award_points` writes the `running_balance` this function reads. If the ledger write pattern changes, verify the correlated subquery here still picks up the latest entry.

**Invariants:**
- `INV-MEMBERS-001` — Only members (rows in `store_memberships`) are returned; non-member users are invisible even if they have ledger entries.
- `INV-MEMBERS-002` — `user_id` is included in the output intentionally: staff need it to call `award_points` and `load_member_recent_transactions`.

**Maintenance checklist:**
- [ ] If `profiles` gains additional columns that should appear in the member list, add them to the SELECT inside the function — never relax the profiles RLS policy instead.
- [ ] If member lists grow large enough to cause performance issues, add pagination parameters and update callers.

---

### `load_store_staff_profiles(p_store_id)`

| Attribute | Value |
|-----------|-------|
| Returns | `json` (array of `{user_id, public_id, created_at}`) |
| Auth gate | Manager of `p_store_id` only |
| Tables read | `store_managers`, `store_staff`, `profiles` |

**What it does:** Returns the staff roster for a store, including public IDs. Manager-only because staff lists reveal organisational information not visible to regular staff.

**Invariants:**
- `INV-STAFFPROF-001` — Only users in `store_staff` for the requested store are returned; managers from other stores are not visible.

**Maintenance checklist:**
- [ ] If staff should also see the roster (e.g. for a "who's on shift" feature), duplicate the auth check to include `store_staff` in the UNION and update this document.

---

### `load_customer_home(p_include_stores)`

| Attribute | Value |
|-----------|-------|
| Returns | `json` (`{public_id, memberships[], stores[]}`) |
| Auth gate | Any authenticated user — scoped to `auth.uid()` |
| Tables read | `profiles`, `store_memberships`, `stores`, `points_ledger`, `store_reward_rules` |

**What it does:** Single-query bootstrap for the customer app. Returns the caller's profile, all their store memberships with current balance, active rules per store, last 10 ledger entries per store, and optionally the full stores list.

**Zero cross-user exposure:** Every subquery is filtered by `v_user_id = auth.uid()`. There is no parameter that accepts a different user ID.

**Invariants:**
- `INV-CUSTHOME-001` — `public_id`, balances, and history returned are always for the calling user. There is no impersonation path.
- `INV-CUSTHOME-002` — Rules returned are filtered by `is_active = true`. Inactive rules are never shown to customers.
- `INV-CUSTHOME-003` — The `stores` list (when `p_include_stores = true`) is the full store catalogue — intentional, so customers can discover stores to join.

**Maintenance checklist:**
- [ ] If the customer history limit changes from 10, update this function and document it here.
- [ ] If rule output should include `id` (e.g. for customer-side rule references), add it explicitly and verify it cannot be used to call staff-only RPCs.

---

### `load_member_recent_transactions(p_user_id, p_store_id)`

| Attribute | Value |
|-----------|-------|
| Returns | `json` (array of `{points, reason, created_at}`, max 5 entries) |
| Auth gate | Staff OR manager of `p_store_id` |
| Tables read | `store_staff`, `store_managers`, `points_ledger` |

**What it does:** Returns the last 5 ledger entries for a specific member at a store. Used in the staff panel to show a customer's recent activity.

**Why an RPC and not a direct query:** The `points_ledger` SELECT RLS policy scopes to `user_id = auth.uid()`. A staff user cannot query another user's rows directly. This RPC bypasses RLS (SECURITY DEFINER) and enforces store-scoped auth in the function body instead.

**Output is intentionally minimal:** `reason` and `created_at` are included but not `created_by` or `running_balance` — staff can see what happened but not who made each entry. Add columns only if there is a clear operational need.

**Invariants:**
- `INV-TXNS-001` — LIMIT 5 is enforced server-side. The client cannot request more rows by omitting a limit.
- `INV-TXNS-002` — Store scoping is double-enforced: the auth check verifies the caller is staff/manager of `p_store_id`, and the ledger query also filters `store_id = p_store_id`.

**Maintenance checklist:**
- [ ] If the limit should be configurable, add a `p_limit integer DEFAULT 5` parameter with a server-side cap (e.g. `LEAST(p_limit, 20)`).
- [ ] If `created_by` should be shown to managers (not staff), split into two functions or add a role-based branch.

---

### `join_store(p_store_id)`

| Attribute | Value |
|-----------|-------|
| Returns | `json` (`{success, user_id, store_id}`) |
| Auth gate | Any authenticated user — caller becomes the member |
| Tables written | `store_memberships` |

**What it does:** Self-service store join. Inserts `(auth.uid(), p_store_id)` into `store_memberships`. Idempotent via `ON CONFLICT DO NOTHING`.

**Invariants:**
- `INV-JOIN-001` — `user_id` is always `auth.uid()`. A user cannot join on behalf of another user.
- `INV-JOIN-002` — An invalid `p_store_id` will raise a FK violation (no corresponding row in `stores`).

---

### `approve_staff_applicant(p_user_id, p_store_id)`

| Attribute | Value |
|-----------|-------|
| Returns | `json` (`{success, user_id, store_id}`) |
| Auth gate | Manager of `p_store_id` |
| Tables written | `store_staff` |
| Tables read | `store_managers`, `store_memberships` |

**What it does:** Promotes a user to staff at a store. The manager auth check and membership guard both run before the INSERT.

**Auth flow:**

```
1. auth.uid() IS NULL → raise 'not authenticated'
2. p_user_id IS NULL OR p_store_id IS NULL → raise
3. caller ∉ store_managers for p_store_id → raise 'not authorized for this store'
4. p_user_id ∉ store_memberships for p_store_id → raise 'user is not a member of this store'
5. INSERT into store_staff ON CONFLICT DO NOTHING
```

**Why the membership guard:** After the applicant system was removed, there was no longer a validated opt-in record confirming the target user intended to become staff. The `store_memberships` check restores a minimum gate: the user must at least have joined the store (which requires their own authenticated session) before a manager can elevate them.

**Invariants:**
- `INV-APPSTAFF-001` — Only a manager of the specific store can call this. Cross-store promotion is blocked.
- `INV-APPSTAFF-002` — The promoted user must already be a member of the store (`INV-MEMB-002`).

**Maintenance checklist:**
- [ ] If a re-application system is introduced, the membership check may need to be replaced or supplemented with a new opt-in gate.
- [ ] If admins should also be able to call this (currently only managers can), add `OR public.is_admin()` to the auth EXISTS check.

---

### `demote_store_staff(p_user_id, p_store_id)`

| Attribute | Value |
|-----------|-------|
| Returns | `json` (`{success, user_id, store_id}`) |
| Auth gate | Manager of `p_store_id` |
| Tables written | `store_staff` |

**What it does:** Removes a user from `store_staff` for a specific store. Does not remove their `store_memberships` row.

**Invariants:**
- `INV-DEMOTE-001` — A manager cannot demote staff at a store they don't manage.
- `INV-DEMOTE-002` — Demotion does not affect `store_memberships`; the user remains a customer of the store.
- `INV-DEMOTE-003` — A manager cannot demote another manager via this function (it only DELETEs from `store_staff`).

---

### `admin_*` RPCs

All admin RPCs share the same auth pattern and are not individually callable by managers or staff:

```sql
IF NOT public.is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
```

| RPC | Action | Tables affected |
|-----|--------|----------------|
| `admin_create_store(p_name)` | INSERT into `stores` | `stores` |
| `admin_update_store(p_store_id, p_name)` | UPDATE `stores.name` | `stores` |
| `admin_remove_store(p_store_id)` | CASCADE DELETE all store data | `points_ledger`, `store_memberships`, `store_staff`, `store_managers`, `store_reward_rules`, `stores` |
| `admin_insert_reward_rule(p_store_id, p_label, p_points, p_kind, p_sort_order)` | INSERT into `store_reward_rules` | `store_reward_rules` |
| `admin_delete_reward_rule(p_id)` | DELETE from `store_reward_rules` | `store_reward_rules` |
| `admin_update_reward_rule_order(p_id, p_sort_order)` | UPDATE `sort_order` | `store_reward_rules` |
| `admin_assign_staff(p_user_id, p_store_id)` | INSERT into `store_staff` | `store_staff` |
| `admin_remove_staff(p_user_id, p_store_id)` | DELETE from `store_staff` | `store_staff` |
| `admin_assign_manager(p_user_id, p_store_id)` | INSERT into `store_managers` | `store_managers` |
| `admin_remove_manager(p_user_id, p_store_id)` | DELETE from `store_managers` | `store_managers` |
| `admin_set_bonus_cap(p_store_id, p_max_bonus_points)` | UPDATE `stores.max_bonus_points` | `stores` |

**Invariant:** `INV-ADMIN-001` — No admin RPC modifies `auth.users` directly. User creation and deletion are handled via Supabase Auth APIs.

**Note on `admin_set_bonus_cap`:** This RPC uses an inline `SELECT EXISTS ... FROM admins` check rather than calling `is_admin()`. Functionally identical — candidate for alignment in a future cleanup.

**Maintenance checklist (all admin RPCs):**
- [ ] If a new table is added that stores per-store data, add DELETE coverage in `admin_remove_store`.
- [ ] If the `admins` table is replaced with a role system, replace all `is_admin()` calls and inline checks simultaneously.

---

## Section 3: Security Best Practices Applied

### SECURITY DEFINER on all write and cross-user read RPCs

All RPCs that write to tables or read data across user boundaries run as the DB owner, not the calling user. This means RLS on the underlying tables does not apply inside the function body. Auth enforcement is the function's explicit responsibility, not RLS. This is why every RPC begins with an `auth.uid()` check and a role/scope validation before touching any table.

### `SET search_path = ''` on every RPC

Without this, a malicious or accidental object in a searched schema could shadow a system function. Setting `search_path = ''` forces every table and function reference to be fully qualified (e.g. `public.store_staff`), eliminating schema injection as an attack surface.

### RESTRICTIVE write policies on all tables

PostgreSQL evaluates RESTRICTIVE policies with AND logic against all permissive policies. A table with `RESTRICTIVE FOR INSERT WITH CHECK (false)` cannot be inserted into by any client regardless of how many permissive INSERT policies exist now or in the future. This is defence in depth: even if a permissive policy is accidentally added, the RESTRICTIVE block holds.

### Advisory locks in `award_points`

`pg_advisory_xact_lock(hashtext(p_user_id::text), hashtext(p_store_id::text))` serialises concurrent calls for the same `(user_id, store_id)` pair at the transaction level. Under PostgreSQL's default READ COMMITTED isolation, two concurrent transactions can both read the same `running_balance` before either commits. The lock prevents the race that would otherwise allow the negative-balance guard to be bypassed by timing.

### Anon role has no table or RPC access

`harden-rls-and-grants.sql` revokes all table and sequence grants from `anon` and revokes EXECUTE on all functions from `anon` and `PUBLIC`. Default privileges are set to prevent future objects from inheriting broad grants. An unauthenticated request cannot call any RPC or read any table.

### `running_balance` is computed server-side

The client never sends a balance value. `award_points` and `adjust_points` both read the previous `running_balance` from the ledger and compute the new value inside the function. This prevents a client from forging an inflated balance via a manipulated RPC call.

### Store scoping on all staff/manager RPCs

Every RPC that a staff or manager calls validates `store_id` against `store_staff` or `store_managers` for the calling user. A staff member at Store A cannot award points, load members, or read transactions for Store B by substituting a different `store_id` parameter.

---

## Section 4: Maintenance Instructions

### When a new table is added

1. Enable RLS immediately: `ALTER TABLE public.new_table ENABLE ROW LEVEL SECURITY;`
2. Add RESTRICTIVE write blocks if the table should only be written by RPCs.
3. Add scoped SELECT policies (own-row, role-scoped, or open depending on sensitivity).
4. Add the table to `admin_remove_store` if it contains per-store data.
5. Revoke anon grants: `REVOKE ALL ON public.new_table FROM anon;`
6. Add a section to this document before the migration runs.

### When a new RPC is added

1. Use `SECURITY DEFINER` and `SET search_path = ''` on every function.
2. Start with `auth.uid() IS NULL → raise`.
3. If it reads or writes data across users, enforce store scoping explicitly.
4. If it writes to `points_ledger`, use the advisory lock pattern from `award_points`.
5. Re-run `harden-rls-and-grants.sql` or add an explicit `GRANT EXECUTE ON FUNCTION ... TO authenticated` in the migration.
6. Add a Section 2 entry to this document.

### When an RPC is modified

1. If the signature changes (added/removed parameters), `DROP FUNCTION` the old signature first — `CREATE OR REPLACE` only replaces an exact signature match.
2. Update the Section 2 entry, invariants, and maintenance checklist.
3. Update callers in `src/services/` to match the new signature.

### When an RLS policy changes

1. Update the relevant Section 1 table entry.
2. Verify any SECURITY DEFINER RPCs that read the affected table still behave correctly (they bypass RLS, so the change won't affect them — but document whether that's still intentional).
3. Test both the permissive and RESTRICTIVE branches: confirm that a row that should be blocked is blocked, and a row that should be visible is visible.

### When the `admins` table or `is_admin()` changes

1. Update every RPC that calls `is_admin()` or uses the inline equivalent.
2. Update `INV-ISADMIN-001` and the admin RPCs section.
3. Note: `admin_set_bonus_cap` uses an inline check — update it alongside `is_admin()`.

### When `store_reward_rules.kind` gains a new value

1. Update the DB CHECK constraint.
2. Update `award_points` if the new kind can be awarded or redeemed.
3. Update `admin_insert_reward_rule` if the new kind requires different point validation.
4. Update `INV-RULES-001` and `INV-RULES-003`.
5. Update the frontend `KIND_LABEL` mapping in `src/pages/admin/start.js`.

---

## Section 5: Machine-Readable Invariant Tags

| Tag | Description | Enforced in |
|-----|-------------|-------------|
| `INV-ADMINS-001` | No client can read/write `admins` | RLS: `auth.role() = 'service_role'` |
| `INV-ADMINS-002` | Admin status requires manual SQL grant | Operational procedure |
| `INV-STORES-001` | No client writes to `stores` | RESTRICTIVE INSERT/UPDATE/DELETE |
| `INV-STORES-002` | `max_bonus_points` ≥ 1 or NULL | `admin_set_bonus_cap` |
| `INV-RULES-001` | `kind` in allowed set | DB CHECK constraint |
| `INV-RULES-002` | Rule validated on award/redeem | `award_points` |
| `INV-RULES-003` | `bonus_reason` rules have `points = 0` | Admin UI + `admin_insert_reward_rule` |
| `INV-MEMB-001` | Users join only as themselves | `join_store` (auth.uid() anchor) |
| `INV-MEMB-002` | Staff promotion requires membership | `approve_staff_applicant` |
| `INV-STAFF-001` | Staff row implies membership (manager path) | `approve_staff_applicant` |
| `INV-STAFF-002` | Managers demote only their own store's staff | `demote_store_staff` |
| `INV-MGR-001` | Only admins assign/remove managers | `admin_assign_manager`, `admin_remove_manager` |
| `INV-MGR-002` | Manager auth gates on `store_managers` row | `load_store_staff_profiles`, `approve_staff_applicant`, `demote_store_staff` |
| `INV-PROF-001` | No client reads another user's profile | RLS: `auth.uid() = user_id` |
| `INV-PROF-002` | RPCs never expose auth email/phone | `load_store_members`, `load_store_staff_profiles` |
| `INV-LEDGER-001` | `running_balance` computed server-side | `award_points`, `adjust_points` |
| `INV-LEDGER-002` | Balance never goes below 0 via `award_points` | `award_points` |
| `INV-LEDGER-003` | `created_by` is always caller's `auth.uid()` | `award_points`, `adjust_points` |
| `INV-LEDGER-004` | Ledger is append-only; no UPDATE or DELETE | RLS (no UPDATE/DELETE policy exists) |
| `INV-ISADMIN-001` | `is_admin()` is the single admin check source | All `admin_*` RPCs |
| `INV-ADMIN-001` | Admin RPCs never touch `auth.users` directly | All `admin_*` RPCs |
| `INV-AWARD-001` | Redemptions always require a rule ID | `award_points` |
| `INV-AWARD-002` | Balance floor of 0 enforced on award/redeem | `award_points` |
| `INV-AWARD-003` | Rule validation checks all four fields | `award_points` |
| `INV-ADJ-001` | Zero adjustment rejected | `adjust_points` |
| `INV-ADJ-002` | No rule validation on adjustments | `adjust_points` (intentional bypass) |
| `INV-MEMBERS-001` | Only store members appear in member list | `load_store_members` |
| `INV-MEMBERS-002` | `user_id` included in member list output | `load_store_members` |
| `INV-STAFFPROF-001` | Staff profiles scoped to requested store | `load_store_staff_profiles` |
| `INV-CUSTHOME-001` | Customer home data scoped to `auth.uid()` | `load_customer_home` |
| `INV-CUSTHOME-002` | Only active rules returned to customers | `load_customer_home` |
| `INV-CUSTHOME-003` | Full store list visible to all customers | `load_customer_home` (intentional) |
| `INV-TXNS-001` | Transaction history capped at 5 server-side | `load_member_recent_transactions` |
| `INV-TXNS-002` | Store scoping double-enforced on transaction read | `load_member_recent_transactions` |
| `INV-JOIN-001` | Store join anchored to caller's `auth.uid()` | `join_store` |
| `INV-JOIN-002` | Invalid `store_id` raises FK violation | `join_store` |
| `INV-APPSTAFF-001` | Only manager of the store can promote | `approve_staff_applicant` |
| `INV-APPSTAFF-002` | Promoted user must be a store member | `approve_staff_applicant` |
| `INV-DEMOTE-001` | Manager can only demote own-store staff | `demote_store_staff` |
| `INV-DEMOTE-002` | Demotion preserves store membership | `demote_store_staff` |
| `INV-DEMOTE-003` | Demotion does not affect `store_managers` | `demote_store_staff` |
