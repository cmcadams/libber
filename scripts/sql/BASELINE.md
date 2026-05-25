# Libber — Frozen Baseline Specification

**Baseline version**: 17  
**Frozen**: 2026-05-25 (extended 2026-05-25)  
**Status**: Files 00–15 immutable. File 16 added `unjoin_store`. File 17 enforces outlet integrity.

This document is the authoritative record of the database state produced by
running migrations 00–15 on an empty Supabase project. Any production database
should match this spec exactly. Drift is an error.

---

## Execution Order

Run in this exact order on a fresh database:

| Step | File | Purpose |
|---|---|---|
| 00 | `00-base-schema.sql` | 7 base tables + RLS enabled |
| 01 | `01-admin-security.sql` | admins table, is_admin(), store/rules write-blocks, admin RPCs |
| 02 | `02-rls-policies.sql` | SELECT policies on all base tables |
| 03 | `03-rls-write-blocks.sql` | Write-block RLS on memberships/staff/ledger; join_store, demote_store_staff |
| 04 | `04-schema-bonus-cap.sql` | stores.max_bonus_points; admin_set_bonus_cap; award_points (intermediate) |
| 05 | `05-schema-bonus-adjust.sql` | kind constraint extended; adjust_points (intermediate) |
| 06 | `06-schema-outlets.sql` | store_outlets table; outlet_id on points_ledger; outlet RPCs |
| 07 | `07-schema-ab-testing.sql` | ab_variants table; profile columns; create_profile trigger |
| 08 | `08-schema-store-logo.sql` | stores.logo_path/logo_updated_at; storage bucket + policies; admin_set_store_logo |
| 09 | `09-rpc-save-account.sql` | mark_account_linked RPC |
| 10 | `10-rbac-helpers.sql` | get_store_role, assert_store_access, assert_store_manager; RBAC indexes |
| 11 | `11-security-hardening.sql` | Realtime; scoped RLS; REVOKE anon; grant lockdown |
| 12 | `12-admin-user-directory.sql` | admin_user_directory view; profiles: select as admin policy |
| 13 | `13-rpc-fixes.sql` | load_member_recent_transactions; advisory lock on adjust_points |
| 14 | `14-soft-delete.sql` | is_active columns; assert_store_active/active_membership; all final RPCs |
| 15 | `15-final-grants.sql` | Final REVOKE anon/PUBLIC + re-grant authenticated on all functions |
| 16 | `16-unjoin-store.sql` | unjoin_store customer RPC |
| 17 | `17-outlet-integrity.sql` | admin_create_store auto-creates 'Main' outlet; admin_delete_outlet blocks last-outlet deletion; backfill for existing stores |

---

## Tables

### `public.profiles`
| Column | Type | Constraints |
|---|---|---|
| user_id | uuid | PK, FK → auth.users ON DELETE CASCADE |
| public_id | text | NOT NULL UNIQUE |
| created_at | timestamptz | NOT NULL DEFAULT now() |
| save_prompt_variant | text | nullable |
| interaction_count | int | NOT NULL DEFAULT 0 |
| one_time_prompt_shown_at | timestamptz | nullable |
| prompt_dismissed_at | timestamptz | nullable |
| account_linked_at | timestamptz | nullable |

RLS: enabled

### `public.stores`
| Column | Type | Constraints |
|---|---|---|
| id | uuid | PK DEFAULT gen_random_uuid() |
| name | text | NOT NULL CHECK (char_length(trim(name)) > 0) |
| created_at | timestamptz | NOT NULL DEFAULT now() |
| max_bonus_points | integer | nullable |
| logo_path | text | nullable |
| logo_updated_at | timestamptz | nullable |
| is_active | boolean | NOT NULL DEFAULT true |
| deleted_at | timestamptz | nullable |

RLS: enabled

### `public.store_memberships`
| Column | Type | Constraints |
|---|---|---|
| user_id | uuid | NOT NULL FK → auth.users ON DELETE CASCADE |
| store_id | uuid | NOT NULL FK → stores ON DELETE CASCADE |
| created_at | timestamptz | NOT NULL DEFAULT now() |
| is_active | boolean | NOT NULL DEFAULT true |

PK: (user_id, store_id)  
RLS: enabled

### `public.store_staff`
| Column | Type | Constraints |
|---|---|---|
| user_id | uuid | NOT NULL FK → auth.users ON DELETE CASCADE |
| store_id | uuid | NOT NULL FK → stores ON DELETE CASCADE |
| created_at | timestamptz | NOT NULL DEFAULT now() |

PK: (user_id, store_id)  
RLS: enabled

### `public.store_managers`
| Column | Type | Constraints |
|---|---|---|
| user_id | uuid | NOT NULL FK → auth.users ON DELETE CASCADE |
| store_id | uuid | NOT NULL FK → stores ON DELETE CASCADE |
| created_at | timestamptz | NOT NULL DEFAULT now() |

PK: (user_id, store_id)  
RLS: enabled

### `public.store_reward_rules`
| Column | Type | Constraints |
|---|---|---|
| id | uuid | PK DEFAULT gen_random_uuid() |
| store_id | uuid | NOT NULL FK → stores ON DELETE CASCADE |
| label | text | NOT NULL |
| points | integer | NOT NULL |
| kind | text | NOT NULL CHECK (kind IN ('award','redeem','bonus_reason','bonus_amount')) |
| sort_order | integer | NOT NULL DEFAULT 0 |
| is_active | boolean | NOT NULL DEFAULT true |
| is_pinned | boolean | NOT NULL DEFAULT false |
| created_at | timestamptz | NOT NULL DEFAULT now() |

RLS: enabled

### `public.points_ledger`
| Column | Type | Constraints |
|---|---|---|
| id | uuid | PK DEFAULT gen_random_uuid() |
| user_id | uuid | NOT NULL FK → auth.users ON DELETE CASCADE |
| store_id | uuid | NOT NULL FK → stores ON DELETE CASCADE |
| points | integer | NOT NULL |
| reason | text | NOT NULL |
| created_by | uuid | nullable FK → auth.users ON DELETE SET NULL |
| running_balance | integer | NOT NULL DEFAULT 0 |
| outlet_id | uuid | nullable FK → store_outlets ON DELETE SET NULL |
| created_at | timestamptz | NOT NULL DEFAULT now() |

RLS: enabled

### `public.admins`
| Column | Type | Constraints |
|---|---|---|
| user_id | uuid | PK FK → auth.users ON DELETE CASCADE |
| created_at | timestamptz | DEFAULT now() |

RLS: enabled

### `public.store_outlets`
| Column | Type | Constraints |
|---|---|---|
| id | uuid | PK DEFAULT gen_random_uuid() |
| store_id | uuid | NOT NULL FK → stores ON DELETE CASCADE |
| name | text | NOT NULL CHECK (char_length(trim(name)) > 0) |
| created_at | timestamptz | NOT NULL DEFAULT now() |

RLS: enabled

### `public.ab_variants`
| Column | Type | Constraints |
|---|---|---|
| id | uuid | PK DEFAULT gen_random_uuid() |
| test_name | text | NOT NULL |
| variant | text | NOT NULL |
| text | text | NOT NULL |
| position | text | NOT NULL DEFAULT 'middle' |
| is_active | boolean | NOT NULL DEFAULT true |
| weight | int | NOT NULL DEFAULT 50 CHECK (weight >= 0) |
| created_at | timestamptz | NOT NULL DEFAULT now() |

UNIQUE: (test_name, variant)  
RLS: enabled

---

## Views

### `public.admin_user_directory`
```sql
SELECT user_id, public_id FROM public.profiles ORDER BY public_id ASC NULLS LAST
```
`security_invoker = true` — RLS applies to the calling user.  
Grants: SELECT to authenticated; anon/PUBLIC revoked.

---

## Triggers

| Trigger | Table | Timing | Function |
|---|---|---|---|
| on_auth_user_created | auth.users | AFTER INSERT FOR EACH ROW | public.create_profile() |

---

## Indexes

| Name | Table | Definition |
|---|---|---|
| admins_user_id_idx | admins | (user_id) |
| store_managers_user_store_idx | store_managers | (user_id, store_id) |
| store_staff_user_store_idx | store_staff | (user_id, store_id) |
| stores_is_active_idx | stores | (is_active) |
| store_memberships_store_active_idx | store_memberships | (store_id, is_active) |
| active_membership_unique | store_memberships | UNIQUE (user_id, store_id) WHERE is_active = true |

---

## Functions

All functions: `SECURITY DEFINER SET search_path = ''` · GRANT EXECUTE TO authenticated · anon/PUBLIC revoked

### Helpers
| Function | Signature | Returns |
|---|---|---|
| is_admin | () | boolean |
| get_store_role | (uuid) | text |
| assert_store_access | (uuid) | void |
| assert_store_manager | (uuid) | void |
| assert_store_active | (uuid) | void |
| assert_active_membership | (uuid, uuid) | void |
| create_profile | () | trigger |

### Admin — stores
| Function | Signature | Returns |
|---|---|---|
| admin_create_store | (text) | json — id, name, is_active, outlet_id (atomically creates a 'Main' outlet) |
| admin_update_store | (uuid, text) | json |
| admin_remove_store | (uuid) | void |
| admin_archive_store | (uuid) | json |
| admin_restore_store | (uuid) | json |
| admin_set_store_logo | (uuid, text) | void |
| admin_set_bonus_cap | (uuid, integer) | void |

### Admin — reward rules
| Function | Signature | Returns |
|---|---|---|
| admin_insert_reward_rule | (uuid, text, integer, text, integer) | json |
| admin_delete_reward_rule | (uuid) | void |
| admin_update_reward_rule_order | (uuid, integer) | void |

### Admin — people
| Function | Signature | Returns |
|---|---|---|
| admin_assign_manager | (uuid, uuid) | void |
| admin_remove_manager | (uuid, uuid) | void |
| admin_assign_staff | (uuid, uuid) | void |
| admin_remove_staff | (uuid, uuid) | void |
| admin_load_store_members | (uuid) | TABLE(user_id uuid) |

### Admin — outlets
| Function | Signature | Returns |
|---|---|---|
| admin_create_outlet | (uuid, text) | json |
| admin_update_outlet | (uuid, text) | json |
| admin_delete_outlet | (uuid) | void — raises exception if outlet is the last one for its store |

### Customer
| Function | Signature | Returns |
|---|---|---|
| join_store | (uuid) | json |
| unjoin_store | (uuid) | json |
| load_customer_home | (boolean) | json |
| mark_account_linked | () | void |

### Staff / Manager
| Function | Signature | Returns |
|---|---|---|
| award_points | (uuid, uuid, integer, text, uuid, uuid) | integer |
| adjust_points | (uuid, uuid, integer, text, uuid) | integer |
| approve_staff_applicant | (uuid, uuid) | json |
| demote_store_staff | (uuid, uuid) | json |
| manager_remove_customer_from_store | (uuid, uuid) | json |
| load_store_members | (uuid) | json |
| load_store_outlets | (uuid) | json |
| load_store_staff_profiles | (uuid) | json |
| load_member_recent_transactions | (uuid, uuid) | json |

**Total: 38 functions**

---

## RLS Policies

### `public.profiles`
| Policy | Operation | Expression |
|---|---|---|
| profiles: select own | SELECT | `auth.uid() = user_id` |
| profiles: select as admin | SELECT | `public.is_admin()` |

### `public.stores`
| Policy | Type | Operation | Expression |
|---|---|---|---|
| stores: allow select | permissive | SELECT | `true` |
| stores: no direct insert | RESTRICTIVE | INSERT | `false` |
| stores: no direct update | RESTRICTIVE | UPDATE | `false` |
| stores: no direct delete | RESTRICTIVE | DELETE | `false` |

### `public.store_memberships`
| Policy | Type | Operation | Expression |
|---|---|---|---|
| memberships: select own | permissive | SELECT | `user_id = auth.uid() AND is_active = true` |
| memberships: no direct insert | RESTRICTIVE | INSERT | `false` |

### `public.store_staff`
| Policy | Type | Operation | Expression |
|---|---|---|---|
| staff: select self | permissive | SELECT | `user_id = auth.uid()` |
| staff: select as manager | permissive | SELECT | `EXISTS (SELECT 1 FROM store_managers WHERE store_id = store_staff.store_id AND user_id = auth.uid())` |
| staff: select as admin | permissive | SELECT | `public.is_admin()` |
| staff: no direct insert | RESTRICTIVE | INSERT | `false` |
| staff: no direct delete | RESTRICTIVE | DELETE | `false` |

### `public.store_managers`
| Policy | Type | Operation | Expression |
|---|---|---|---|
| managers: allow select | permissive | SELECT | `user_id = auth.uid() OR public.is_admin()` |
| managers: no direct insert | RESTRICTIVE | INSERT | `false` |
| managers: no direct delete | RESTRICTIVE | DELETE | `false` |

### `public.points_ledger`
| Policy | Type | Operation | Expression |
|---|---|---|---|
| ledger: select own | permissive | SELECT | `user_id = auth.uid()` |
| ledger: no direct insert | RESTRICTIVE | INSERT | `false` |

### `public.store_reward_rules`
| Policy | Type | Operation | Expression |
|---|---|---|---|
| rules: allow select | permissive | SELECT | `true` |
| rules: no direct insert | RESTRICTIVE | INSERT | `false` |
| rules: no direct update | RESTRICTIVE | UPDATE | `false` |
| rules: no direct delete | RESTRICTIVE | DELETE | `false` |

### `public.admins`
| Policy | Type | Operation | Expression |
|---|---|---|---|
| admins: service role only | permissive | ALL | `auth.role() = 'service_role'` |

### `public.store_outlets`
| Policy | Type | Operation | Expression |
|---|---|---|---|
| outlets: authenticated read | permissive | SELECT | `auth.role() = 'authenticated'` |
| outlets: no direct insert | RESTRICTIVE | INSERT | `false` |
| outlets: no direct update | RESTRICTIVE | UPDATE | `false` |
| outlets: no direct delete | RESTRICTIVE | DELETE | `false` |

### `public.ab_variants`
| Policy | Type | Operation | Expression |
|---|---|---|---|
| ab_variants: allow select | permissive | SELECT | `true` |
| ab_variants: no direct insert | RESTRICTIVE | INSERT | `false` |
| ab_variants: no direct update | RESTRICTIVE | UPDATE | `false` |
| ab_variants: no direct delete | RESTRICTIVE | DELETE | `false` |

---

## Storage

| Bucket | Public |
|---|---|
| store-logos | true |

### Storage policies on `storage.objects`
| Policy | Operation | Condition |
|---|---|---|
| store logos are publicly readable | SELECT | `bucket_id = 'store-logos'` |
| admins can upload logos | INSERT (authenticated) | `bucket_id = 'store-logos' AND public.is_admin()` |
| admins can update logos | UPDATE (authenticated) | `bucket_id = 'store-logos' AND public.is_admin()` |

---

## Realtime

`points_ledger` is included in the `supabase_realtime` publication.  
RLS (`ledger: select own`) filters Realtime events to each user's own rows.

---

## Grant Summary

- `anon` role: no EXECUTE on any function, no SELECT/INSERT/UPDATE/DELETE on any table
- `authenticated` role: EXECUTE on all 37 functions; table access controlled entirely by RLS
- `service_role`: bypasses RLS (Supabase default); used only for admin seeding via dashboard
