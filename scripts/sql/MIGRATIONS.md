# Libber — SQL Migration Governance

## Status

**Baseline frozen at migration 15.**
Files `00` through `15` are immutable. Do not edit them.

---

## Migration Discipline

### The single rule

Every schema change is a new numbered SQL file. Nothing else.

```
00-base-schema.sql      ← FROZEN
01-admin-security.sql   ← FROZEN
...
15-final-grants.sql     ← FROZEN
────────────────────────────────
16-<description>.sql    ← next change goes here
17-<description>.sql    ← the one after that
```

No exceptions. A change that is not in a numbered file does not exist.

---

## File Naming

```
<number>-<kebab-description>.sql
```

- Number is zero-padded to two digits: `16`, `17`, ... `99`, then `100`, `101`
- Description is lowercase kebab: `add-store-hours`, `rename-public-id`
- No spaces, no camelCase, no version suffixes (`v2`, `final`, `new`)
- One logical change per file — do not bundle unrelated changes

---

## What Each Migration File Must Contain

Every migration file must be:

1. **Idempotent** — safe to re-run. Use `IF NOT EXISTS`, `CREATE OR REPLACE`, `DROP … IF EXISTS`, `ON CONFLICT DO NOTHING`.
2. **Self-contained** — does not depend on running any other script first except the numbered migrations before it.
3. **Documented** — the first block is a comment header:

```sql
-- <number>-<description>.sql
--
-- What this migration does (one paragraph).
-- What it depends on (which earlier migration added the tables/columns it uses).
-- Whether it needs fix-default-privileges.sql / 15-final-grants.sql re-run.
--
-- Safe to re-run: yes/no (and why if no).
```

4. **Ending with grants** — any new function must have an explicit `GRANT EXECUTE … TO authenticated` at the bottom of the file. Do not rely solely on the batch grant in `15-final-grants.sql` being re-run.

---

## How to Add a New Feature

### Adding a new table

```sql
-- In your new migration file:
CREATE TABLE IF NOT EXISTS public.new_table (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id   uuid        NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.new_table ENABLE ROW LEVEL SECURITY;

-- Add your policies here
-- Add your write-block RESTRICTIVE policies here
```

Never add a table to `00-base-schema.sql`. Never.

### Adding a new column

```sql
ALTER TABLE public.existing_table
  ADD COLUMN IF NOT EXISTS new_column text;
```

### Adding a new function

```sql
CREATE OR REPLACE FUNCTION public.my_new_function(...)
RETURNS ...
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  ...
END $$;

GRANT EXECUTE ON FUNCTION public.my_new_function(...) TO authenticated;
```

All functions must be `SECURITY DEFINER SET search_path = ''`. No exceptions.

### Modifying an existing function

`CREATE OR REPLACE` the function in the new migration file. The new file's version wins.

```sql
-- 17-fix-load-customer-home.sql
-- Updates load_customer_home to include new_field added in 16-add-new-field.sql.

CREATE OR REPLACE FUNCTION public.load_customer_home(p_include_stores boolean DEFAULT true)
RETURNS json
...
```

The baseline file (`14-soft-delete.sql`) is **not touched**. The function definition in file 17 is the live version after a full rebuild.

### Deprecating a function

If a function is no longer called by any client code:

```sql
-- 18-deprecate-old-fn.sql
-- Removes public.old_function — no longer called after client update in v2.3.

DROP FUNCTION IF EXISTS public.old_function(uuid, text);
```

Do not leave dead functions in the database. They consume grants and appear in audits.

---

## What You Must Never Do

| ❌ Forbidden | ✅ Instead |
|---|---|
| Edit any file 00–15 | Create a new migration (16+) that alters or replaces |
| Add a column inline in an existing migration | New migration with `ALTER TABLE … ADD COLUMN IF NOT EXISTS` |
| Run ad-hoc SQL in the dashboard without a migration file | Write the file first, run it, commit it |
| Run migrations out of order | Always run sequentially from the lowest unrun number |
| Use the service role key in client-side code | All mutations go through SECURITY DEFINER RPCs |
| Create a function without `SET search_path = ''` | Always set it |
| Create a function without a GRANT | Always add the explicit grant |

---

## Running Migrations

### Fresh rebuild (empty database)

Run files 00–15 in order. Then run `15-final-grants.sql` last.

```
00 → 01 → 02 → 03 → 04 → 05 → 06 → 07 → 08 → 09
→ 10 → 11 → 12 → 13 → 14 → 15
```

Every file is safe to run in the Supabase SQL Editor.

### Adding a new migration to an existing database

1. Write the migration file: `16-<description>.sql`
2. Run it in the Supabase SQL Editor on staging first
3. Verify against the drift-check queries in `verify-baseline.sql`
4. Run on production
5. Commit the file — the commit is your migration record

### After any migration that creates or replaces functions

Re-run `15-final-grants.sql`. This re-revokes anon/PUBLIC grants and re-grants to authenticated. Supabase's `supabase_admin` default privileges can restore broad grants on `CREATE OR REPLACE FUNCTION`.

---

## Avoiding Duplicate Function Definitions

When a function is replaced by a later migration, **only the latest definition matters**.

The rebuild chain already handles this: a function defined in step 07 and replaced in step 14 ends in the state from step 14 because files run in order.

For new migrations (16+), the same rule applies:
- If you replace a function, the **highest-numbered file** containing it is authoritative
- Add a comment: `-- Replaces the version in 14-soft-delete.sql`
- Never define the same function twice in the same file

To find all definitions of a function across the repo before touching it:
```bash
grep -rn "FUNCTION public.my_function" scripts/sql/
```

---

## Checking Production State

Run `verify-baseline.sql` to confirm production matches the baseline.

Any row returned by the drift queries is a problem.

---

## Migration Log

| File | Description | Date |
|---|---|---|
| 00–15 | Initial build — full schema, RBAC, ledger, soft-delete, A/B, logos | 2026-05 |
| 16 | `unjoin_store` — soft-removes caller's membership (was missing from canonical rebuild) | 2026-05 |
| 17 | Outlet integrity — `admin_create_store` atomically creates 'Main' outlet; `admin_delete_outlet` blocks last-outlet deletion with store-scoped advisory lock; backfill for existing stores | 2026-05 |
| 18 | Profile backfill — creates `profiles` rows for any `auth.users` entry that lacks one (trigger gap fix) | 2026-05 |
| 19 | Fix `create_profile` trigger — floor instead of ceil for public_id generation; uniqueness retry loop; EXCEPTION handler logs warnings instead of silent failure | 2026-05 |

> Add a row here when merging a new migration. Date format: YYYY-MM.
