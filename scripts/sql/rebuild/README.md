# Gotya — Clean Database Rebuild

Consolidated from the 22-file migration chain (00–21). Run these 8 files in order
on a fresh Supabase project. **Do not run on an existing live database.**

## Run order

| File | Contents |
|------|----------|
| `01-schema.sql` | All tables (every column baked in), indexes, seed data, storage bucket, realtime publication |
| `02-triggers.sql` | `create_profile()` trigger function + `on_auth_user_created` trigger |
| `03-auth-helpers.sql` | `is_admin()`, `get_store_role()`, `assert_store_access/manager/active()`, `assert_active_membership()` |
| `04-rls.sql` | All RLS policies (SELECT + RESTRICTIVE write blocks for every table, storage policies) |
| `05-rpcs-customer.sql` | `load_customer_home`, `load_points_history`, `join_store`, `unjoin_store`, `mark_account_linked` |
| `06-rpcs-staff.sql` | `award_points`, `adjust_points`, `load_store_members`, `load_store_staff_profiles`, `load_store_outlets`, `load_member_recent_transactions`, `approve_staff_applicant`, `demote_store_staff`, `manager_remove_customer_from_store` |
| `07-rpcs-admin.sql` | All `admin_*` RPCs + `admin_user_directory` view |
| `08-grants.sql` | Revoke anon/PUBLIC, grant SELECT on 6 tables, grant EXECUTE on all functions |

## After running all files

1. Insert your admin user in Supabase Dashboard → SQL Editor:
   ```sql
   INSERT INTO public.admins (user_id) VALUES ('<your-auth-uid>');
   ```

2. In Supabase Dashboard → Authentication → Providers: enable Google (and Apple if needed).

3. In Authentication → URL Configuration → Redirect URLs, add:
   - `https://<your-domain>/apps/customer/save.html`
   - `http://localhost:5173/apps/customer/save.html`

4. In Authentication → Sign In / Up:
   - Enable "Allow anonymous sign-ins"
   - Enable "Allow manual linking"

## Adding future changes

New schema changes get a new numbered file: `09-xxx.sql`. Re-run `08-grants.sql`
after any file that creates or replaces functions.

## Key invariants

- Every store has at least one outlet (`admin_create_store` creates 'Main' atomically).
- `points_ledger` is append-only (`running_balance` always computed server-side).
- `adjust_points` has no balance floor — by design, product requirement.
- `adjust_points` is available to staff, not just managers — product requirement.
- All writes go through `SECURITY DEFINER` RPCs. Direct client mutations are
  blocked by RESTRICTIVE RLS policies on every table.
- `anon` role has zero privileges on any table, sequence, or function.
