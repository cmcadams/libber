# Libber Backend Contract — v1

**Document type:** LOCKED SPECIFICATION  
**Status:** Frozen at migration 21 (2026-05-26). Do not edit this document without a corresponding numbered migration and a matching update to the version number.  
**Source of truth:** `scripts/sql/` migration chain 00–21 + `docs/security-contract.md` (detailed security invariants).

---

## Migration chain

| # | File | Description |
|---|------|-------------|
| 00 | `00-base-schema.sql` | Core tables: `stores`, `store_memberships`, `store_staff`, `store_managers`, `store_reward_rules`, `profiles`, `points_ledger` |
| 01 | `01-admin-security.sql` | `admins` table, `is_admin()` |
| 02 | `02-rls-policies.sql` | Permissive RLS SELECT policies |
| 03 | `03-rls-write-blocks.sql` | RESTRICTIVE INSERT/UPDATE/DELETE blocks on all tables |
| 04 | `04-schema-bonus-cap.sql` | `stores.max_bonus_points` column |
| 05 | `05-schema-bonus-adjust.sql` | `adjust_points` RPC |
| 06 | `06-schema-outlets.sql` | `store_outlets` table + outlet RPCs |
| 07 | `07-schema-ab-testing.sql` | A/B testing tables (`ab_variants`, `ab_assignments`) |
| 08 | `08-schema-store-logo.sql` | `stores.logo_path`, `stores.logo_updated_at`, `admin_set_store_logo` |
| 09 | `09-rpc-save-account.sql` | `customer_saves` table, `mark_account_linked` |
| 10 | `10-rbac-helpers.sql` | `assert_store_access`, `assert_store_manager`, `assert_store_active`, `assert_active_membership`, `get_store_role` helper functions |
| 11 | `11-security-hardening.sql` | Revoke all anon/PUBLIC grants; `SET search_path = ''` on all RPCs; default privilege restrictions |
| 12 | `12-admin-user-directory.sql` | `admin_user_directory` view (`security_invoker = true`) |
| 13 | `13-rpc-fixes.sql` | Signature and logic fixes on existing RPCs |
| 14 | `14-soft-delete.sql` | `stores.is_active`, `stores.deleted_at`; `admin_archive_store`, `admin_restore_store`, `manager_remove_customer_from_store`; lifecycle guard in write RPCs |
| 15 | `15-final-grants.sql` | `GRANT EXECUTE` on all RPCs to `authenticated` (re-run after any RPC change) |
| 16 | `16-unjoin-store.sql` | `unjoin_store` RPC |
| 17 | `17-outlet-integrity.sql` | FK and integrity fixes on `store_outlets` |
| 18 | `18-backfill-profiles.sql` | Backfill missing `profiles` rows for existing `auth.users` |
| 19 | `19-fix-create-profile.sql` | Fix `create_profile` trigger timing |
| 20 | `20-grant-authenticated-select.sql` | Restore explicit SELECT grants on the 6 tables queried directly by the client |
| 21 | `21-ledger-hardening.sql` | RESTRICTIVE UPDATE/DELETE on `points_ledger`; add no-direct-insert policy |

---

## Database schema

### `admins`

| Column | Type | Notes |
|--------|------|-------|
| `user_id` | `uuid` PK | FK → `auth.users(id) ON DELETE CASCADE` |
| `created_at` | `timestamptz` | Default `now()` |

RLS: service role only (full block for all authenticated clients).

---

### `stores`

| Column | Type | Notes |
|--------|------|-------|
| `id` | `uuid` PK | |
| `name` | `text` | |
| `max_bonus_points` | `integer` | Nullable — `NULL` = no cap |
| `logo_path` | `text` | Nullable — storage path within `store-logos` bucket |
| `logo_updated_at` | `timestamptz` | Nullable — used as cache-bust query param |
| `is_active` | `boolean` | Default `true`; `false` = archived (soft-deleted) |
| `deleted_at` | `timestamptz` | Nullable — set when archived |

RLS: SELECT open to all authenticated users. INSERT/UPDATE/DELETE RESTRICTIVE `false`.

---

### `store_reward_rules`

| Column | Type | Notes |
|--------|------|-------|
| `id` | `uuid` PK | |
| `store_id` | `uuid` | FK → `stores(id)` |
| `label` | `text` | |
| `points` | `integer` | |
| `kind` | `text` | CHECK: `award` \| `redeem` \| `bonus_reason` \| `bonus_amount` |
| `sort_order` | `integer` | |
| `is_active` | `boolean` | |
| `is_pinned` | `boolean` | Reserved |

RLS: SELECT open. INSERT/UPDATE/DELETE RESTRICTIVE `false`.

---

### `store_memberships`

| Column | Type | Notes |
|--------|------|-------|
| `user_id` | `uuid` | FK → `auth.users(id)` |
| `store_id` | `uuid` | FK → `stores(id)` |
| `created_at` | `timestamptz` | |

PK: `(user_id, store_id)`.  
RLS: SELECT own-row only. INSERT RESTRICTIVE `false`.

---

### `store_staff`

| Column | Type | Notes |
|--------|------|-------|
| `user_id` | `uuid` | FK → `auth.users(id)` |
| `store_id` | `uuid` | FK → `stores(id)` |
| `created_at` | `timestamptz` | |

PK: `(user_id, store_id)`.  
RLS: SELECT by self, manager of same store, or admin. INSERT/DELETE RESTRICTIVE `false`.

---

### `store_managers`

| Column | Type | Notes |
|--------|------|-------|
| `user_id` | `uuid` | FK → `auth.users(id)` |
| `store_id` | `uuid` | FK → `stores(id)` |

PK: `(user_id, store_id)`.  
RLS: SELECT by self or admin. INSERT/DELETE RESTRICTIVE `false`.

---

### `profiles`

| Column | Type | Notes |
|--------|------|-------|
| `user_id` | `uuid` PK | FK → `auth.users(id)` |
| `public_id` | `text` | Display-safe human-readable ID |

RLS: SELECT by self or admin. No write policies (populated by `create_profile` trigger).

**View:** `admin_user_directory` — `security_invoker = true` over `profiles`, ordered by `public_id`. Respects caller's RLS context.

---

### `points_ledger`

| Column | Type | Notes |
|--------|------|-------|
| `user_id` | `uuid` | FK → `auth.users(id)` |
| `store_id` | `uuid` | FK → `stores(id)` |
| `points` | `integer` | Positive = award; negative = redemption or deduction |
| `reason` | `text` | Human-readable label |
| `created_by` | `uuid` | Staff/manager `auth.uid()` at time of write |
| `running_balance` | `integer` | Balance after this entry — computed inside RPC only |
| `created_at` | `timestamptz` | Default `now()` |

RLS: SELECT own-row only. INSERT/UPDATE/DELETE RESTRICTIVE `false`. **Append-only by design.**

---

### `store_outlets`

| Column | Type | Notes |
|--------|------|-------|
| `id` | `uuid` PK | |
| `store_id` | `uuid` | FK → `stores(id)` |
| `name` | `text` | |
| `is_active` | `boolean` | |

RLS: SELECT open. INSERT/UPDATE/DELETE RESTRICTIVE `false`.

---

### `ab_variants`

| Column | Type | Notes |
|--------|------|-------|
| `id` | `uuid` PK | |
| `test_name` | `text` | |
| `variant` | `text` | e.g. `A`, `B` |
| `text` | `text` | Display text |
| `position` | `text` | UI position hint |
| `weight` | `integer` | Selection weight |
| `is_active` | `boolean` | |

Seed-only table — written via SQL editor, not via RPC.

---

### `customer_saves`

Tracks whether a customer has linked their anonymous account to a persistent account. Used by the save-account flow.

---

## RPC function catalogue

All RPCs use `SECURITY DEFINER SET search_path = ''` unless noted as a helper. All parameters use the `p_` prefix.

---

### Auth helpers (called by other RPCs, not directly by client data paths)

| Function | Returns | Purpose |
|----------|---------|---------|
| `is_admin()` | `boolean` | Single source of admin truth. Reads `admins` table. STABLE. |
| `assert_store_access(p_store_id)` | `void` (raises on failure) | Verifies caller is in `store_staff` OR `store_managers` for `p_store_id` AND store is active. |
| `assert_store_manager(p_store_id)` | `void` | Verifies caller is in `store_managers` for `p_store_id`. |
| `assert_store_active(p_store_id)` | `void` | Verifies `stores.is_active = true` and `deleted_at IS NULL`. |
| `assert_active_membership(p_user_id, p_store_id)` | `void` | Verifies `p_user_id` has a row in `store_memberships` for `p_store_id`. |
| `get_store_role(p_store_id)` | `text` | Returns `'manager'`, `'staff'`, or `'none'` for the calling user at a store. |
| `create_profile()` | trigger function | Creates a `profiles` row on `auth.users` INSERT. |

---

### Customer RPCs

#### `load_customer_home(p_include_stores boolean DEFAULT true)`

| | |
|---|---|
| **Returns** | `json` — `{public_id, memberships[], stores[]}` |
| **Auth gate** | Any authenticated user — scoped entirely to `auth.uid()` |
| **Tables read** | `profiles`, `store_memberships`, `stores`, `points_ledger`, `store_reward_rules` |

Single-query bootstrap for the customer app. Returns the caller's profile, all memberships with current balance, active rules per store, last 10 ledger entries per store, and optionally the full store catalogue.

No `p_user_id` parameter — identity is `auth.uid()` only. No impersonation path exists.

---

#### `load_points_history(p_store_id uuid)`

| | |
|---|---|
| **Returns** | `json` — array of `{points, reason, created_at}`, max 10 rows |
| **Auth gate** | Any authenticated user — scoped to `auth.uid()` |
| **Tables read** | `points_ledger` |

Returns the caller's own transaction history for one store. Columns returned: `points`, `reason`, `created_at` only. `created_by` and `running_balance` are never included.

---

#### `join_store(p_store_id uuid)`

| | |
|---|---|
| **Returns** | `json` — `{success, user_id, store_id}` |
| **Auth gate** | Any authenticated user |
| **Tables written** | `store_memberships` |

Self-service store join. `user_id` is always `auth.uid()`. Idempotent via `ON CONFLICT DO NOTHING`.

---

#### `unjoin_store(p_store_id uuid)`

| | |
|---|---|
| **Returns** | `json` |
| **Auth gate** | Any authenticated user |
| **Tables written** | `store_memberships` (DELETE) |

Self-service store leave. Removes the caller's membership. Does not affect `points_ledger` — balance is preserved.

---

#### `mark_account_linked()`

| | |
|---|---|
| **Returns** | `void` |
| **Auth gate** | Any authenticated user |
| **Tables written** | `customer_saves` |

Records that the calling user has linked their anonymous session to a persistent account (e.g. Google OAuth).

---

### Staff / manager RPCs

#### `award_points(p_user_id, p_store_id, p_points, p_reason, p_rule_id, p_outlet_id)`

| | |
|---|---|
| **Returns** | `integer` (new balance) |
| **Auth gate** | Staff OR manager of `p_store_id` |
| **Tables written** | `points_ledger` |
| **Advisory lock** | `pg_advisory_xact_lock(hashtext(p_user_id), hashtext(p_store_id))` |

Full guard chain: auth → RBAC (`assert_store_access`) → lifecycle (`assert_store_active`) → membership (`assert_active_membership`) → rule validation → balance floor check → advisory lock → INSERT.

- Positive `p_points` with `p_rule_id`: validates rule matches `store_id`, `is_active`, `kind='award'`, `points`.
- Positive `p_points` without `p_rule_id`: checks bonus cap (`max_bonus_points`).
- Negative `p_points`: requires `p_rule_id` with `kind='redeem'`. Redemptions always require a rule.
- Balance floor: `new_balance < 0` raises `'insufficient points'`.
- `running_balance` is computed server-side. Client never sends a balance.

---

#### `adjust_points(p_user_id, p_store_id, p_points, p_reason, p_outlet_id)`

| | |
|---|---|
| **Returns** | `integer` (new balance) |
| **Auth gate** | Staff OR manager of `p_store_id` |
| **Tables written** | `points_ledger` |

Manual correction path. No rule validation. No bonus cap. **No balance floor** — staff corrections may produce negative balances intentionally. This is a product requirement and must not be restricted to managers.

---

#### `load_store_members(p_store_id uuid)`

| | |
|---|---|
| **Returns** | `json` — array of `{user_id, public_id, balance}` |
| **Auth gate** | Staff OR manager of `p_store_id` |
| **Tables read** | `store_staff`, `store_managers`, `store_memberships`, `profiles`, `points_ledger` |

Full member list with current balance. Balance is the `running_balance` of the most recent ledger entry. Returns only members with a row in `store_memberships`.

---

#### `load_store_staff_profiles(p_store_id uuid)`

| | |
|---|---|
| **Returns** | `json` — array of `{user_id, public_id, created_at}` |
| **Auth gate** | Manager of `p_store_id` only (not staff) |
| **Tables read** | `store_managers`, `store_staff`, `profiles` |

Staff roster for the store. Manager-only because staff lists reveal organisational information.

---

#### `load_member_recent_transactions(p_user_id, p_store_id)`

| | |
|---|---|
| **Returns** | `json` — array of `{points, reason, created_at}`, max 5 rows |
| **Auth gate** | Staff OR manager of `p_store_id` |
| **Tables read** | `store_staff`, `store_managers`, `points_ledger` |

Last 5 ledger entries for one member at one store. LIMIT 5 enforced server-side. `created_by` and `running_balance` are never returned.

---

#### `load_store_outlets(p_store_id uuid)`

| | |
|---|---|
| **Returns** | `json` — array of `{id, name, is_active}` |
| **Auth gate** | Staff OR manager of `p_store_id` |
| **Tables read** | `store_outlets` |

Active outlets for a store. Used by staff to select the outlet when awarding points.

---

#### `approve_staff_applicant(p_user_id, p_store_id)`

| | |
|---|---|
| **Returns** | `json` — `{success, user_id, store_id}` |
| **Auth gate** | Manager of `p_store_id` |
| **Tables written** | `store_staff` |

Promotes a user to staff. Requires the target user to already be a member of the store. Cross-store promotion is blocked.

---

#### `demote_store_staff(p_user_id, p_store_id)`

| | |
|---|---|
| **Returns** | `json` — `{success, user_id, store_id}` |
| **Auth gate** | Manager of `p_store_id` |
| **Tables written** | `store_staff` (DELETE) |

Removes a user from `store_staff`. Does not affect `store_memberships` (user remains a customer). Does not affect `store_managers`.

---

#### `manager_remove_customer_from_store(p_user_id, p_store_id)`

| | |
|---|---|
| **Returns** | `json` |
| **Auth gate** | Manager of `p_store_id` |
| **Tables written** | `store_memberships` (DELETE), `store_staff` (DELETE if applicable) |

Removes a customer's membership from the store entirely. Also removes any `store_staff` row. Does not remove `store_managers` rows (managers must be demoted by admin first).

---

### Admin RPCs

All admin RPCs begin with:
```sql
IF NOT public.is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
```

#### Store management

| RPC | Parameters | Action |
|-----|-----------|--------|
| `admin_create_store(p_name)` | `text` | INSERT into `stores` |
| `admin_update_store(p_store_id, p_name)` | `uuid, text` | UPDATE `stores.name` |
| `admin_remove_store(p_store_id)` | `uuid` | CASCADE DELETE all store data from `points_ledger`, `store_memberships`, `store_staff`, `store_managers`, `store_reward_rules`, `store_outlets`, `stores` |
| `admin_archive_store(p_store_id)` | `uuid` | Set `is_active = false`, `deleted_at = now()` |
| `admin_restore_store(p_store_id)` | `uuid` | Set `is_active = true`, `deleted_at = NULL` |
| `admin_set_bonus_cap(p_store_id, p_max_bonus_points)` | `uuid, integer` | UPDATE `stores.max_bonus_points`; NULL = remove cap |
| `admin_set_store_logo(p_store_id, p_logo_path)` | `uuid, text` | UPDATE `stores.logo_path` and `logo_updated_at` |

#### Reward rules

| RPC | Parameters | Action |
|-----|-----------|--------|
| `admin_insert_reward_rule(p_store_id, p_label, p_points, p_kind, p_sort_order)` | `uuid, text, integer, text, integer` | INSERT into `store_reward_rules` |
| `admin_delete_reward_rule(p_id)` | `uuid` | DELETE from `store_reward_rules` |
| `admin_update_reward_rule_order(p_id, p_sort_order)` | `uuid, integer` | UPDATE `sort_order` |

#### Outlets

| RPC | Parameters | Action |
|-----|-----------|--------|
| `admin_create_outlet(p_store_id, p_name)` | `uuid, text` | INSERT into `store_outlets` |
| `admin_update_outlet(p_outlet_id, p_name)` | `uuid, text` | UPDATE `store_outlets.name` |
| `admin_delete_outlet(p_outlet_id)` | `uuid` | DELETE from `store_outlets` — uses advisory lock to prevent concurrent deletes |

#### Staff and manager assignment

| RPC | Parameters | Action |
|-----|-----------|--------|
| `admin_assign_staff(p_user_id, p_store_id)` | `uuid, uuid` | INSERT into `store_staff` |
| `admin_remove_staff(p_user_id, p_store_id)` | `uuid, uuid` | DELETE from `store_staff` |
| `admin_assign_manager(p_user_id, p_store_id)` | `uuid, uuid` | INSERT into `store_managers` |
| `admin_remove_manager(p_user_id, p_store_id)` | `uuid, uuid` | DELETE from `store_managers` |

#### Data reads (admin-only)

| RPC / View | Returns | Notes |
|-----------|---------|-------|
| `admin_load_store_members(p_store_id)` | `TABLE(user_id uuid)` | All member UUIDs for a store — cross-referenced with `admin_user_directory` for public IDs |
| `admin_user_directory` (view) | `{user_id, public_id}` | `security_invoker = true`; admin sees all, non-admin sees own row only |
| Direct query: `stores` | all columns | Open SELECT for all authenticated users |
| Direct query: `store_managers` | `user_id` | Scoped by RLS to own rows or admin |
| Direct query: `store_staff` | `user_id` | Scoped by RLS to self, manager of same store, or admin |
| Direct query: `store_reward_rules` | all columns | Open SELECT |
| Direct query: `profiles` | own row or all (admin) | Scoped by RLS |
| Realtime: `points_ledger` | INSERT events | Scoped by RLS to `user_id = auth.uid()`; used as signal only — payload is ignored, callback calls `load_customer_home` |

---

## Core security model

```
Client (anon key)
  │
  ├─ Direct table query → RLS enforced at caller identity
  │    ✓ OK for own-row reads
  │    ✗ Never for cross-user data
  │
  └─ supabase.rpc() → SECURITY DEFINER function
       Auth checked inside function body via auth.uid()
       RLS bypassed — function runs as DB owner
       Store scoping enforced explicitly in function logic
```

**Three roles:**

| Role | Access |
|------|--------|
| `anon` | No table privileges, no RPC execute |
| `authenticated` | RPC execute only; table reads scoped by RLS |
| `service_role` | Full bypass — `admins` table management only |

**Non-negotiable constraints:**

1. All write operations go through RPCs. Direct client table mutations are blocked by RESTRICTIVE RLS policies that `false` on every write operation.
2. `running_balance` in `points_ledger` is always computed server-side inside `award_points` / `adjust_points`. The client never sends a balance value.
3. `points_ledger` is append-only. There is no UPDATE or DELETE path for any role below `service_role`.
4. `adjust_points` has no negative balance floor. This is a product requirement for staff corrections.
5. `adjust_points` is available to staff as well as managers. Do not restrict it to managers.
6. `is_admin()` is the single source of admin truth. Do not inline the check.
7. All RPCs use `SECURITY DEFINER SET search_path = ''`.
8. `anon` role has no grants on any table or RPC.
9. After any RPC is added or modified, `15-final-grants.sql` must be re-run.
10. `created_by` (staff UUID) appears in the realtime WAL payload but is never returned by any RPC and is never consumed by any frontend code.

---

## Known gaps (do not address without a new migration)

- **No idempotency on `award_points` / `adjust_points`** — network retry = duplicate write. No `idempotency_key` column exists.
- **`adjust_points` has no balance floor** — intentional, but means staff can set balance to any negative value.
- **`created_by` in realtime payload** — present in WAL stream; ignored by client. PostgreSQL 15 column-list publications could eliminate this but need environment testing.

---

## Future backend improvements (DO NOT IMPLEMENT)

These are known improvements that have been identified but must not be implemented without explicit decision and a new numbered migration:

- Add `idempotency_key` column to `points_ledger` for network-retry safety.
- Add a negative balance floor option to `adjust_points` (configurable per store).
- Add PostgreSQL 15 column-list publication on `points_ledger` to exclude `created_by` from the realtime WAL stream.
- Add pagination parameters to `load_store_members` for large member lists.
- Add `admin_toggle_reward_rule` RPC for toggling `is_active` without deleting a rule.
- Add `admin_update_reward_rule` RPC for editing rule labels.
- Add a configurable `p_limit` parameter to `load_member_recent_transactions` (server-side cap required).
- Align `admin_set_bonus_cap` to use `is_admin()` instead of its current inline `SELECT EXISTS FROM admins` check.
- Add an `apply_for_staff` opt-in system if self-service staff promotion is ever re-introduced.
