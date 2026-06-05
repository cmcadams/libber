-- 08-grants.sql
--
-- All privilege grants. Run LAST — every function and table must exist first.
-- Re-run this file any time a function is added or replaced (CREATE OR REPLACE
-- resets default privileges in Supabase, which can restore broad anon grants).
--
-- Strategy:
--   1. Revoke all execute from anon and PUBLIC (belt-and-suspenders).
--   2. Revoke all table/sequence privileges from anon.
--   3. Set default privileges so future objects don't inherit broad grants.
--   4. Grant SELECT on the exact tables queried directly by client code.
--   5. Grant EXECUTE on all functions to authenticated (dynamic, so no function
--      signature needs to be hard-coded here).
--   6. Grant SELECT on the admin_user_directory view.
--
-- The anon role (unauthenticated requests) should hold zero privileges on any
-- table, sequence, or function in this app. All access requires authentication.
--
-- Audit: no changes required.

-- ── 1 & 2. Revoke from anon and PUBLIC ───────────────────────────────────────

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM anon, PUBLIC;
REVOKE ALL     ON ALL TABLES    IN SCHEMA public FROM anon;
REVOKE ALL     ON ALL SEQUENCES IN SCHEMA public FROM anon;

-- ── 3. Default privileges ─────────────────────────────────────────────────────
-- Prevents future CREATE TABLE / CREATE FUNCTION from inheriting broad grants.

ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES    FROM anon, PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon, PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM anon, PUBLIC;

-- ── 4. Table SELECT grants to authenticated ───────────────────────────────────
-- Only tables with confirmed direct client queries (grep src/ for supabase.from).
-- Tables accessed exclusively via SECURITY DEFINER RPCs are intentionally omitted:
--   store_memberships → join_store, unjoin_store, load_customer_home, etc.
--   store_outlets     → load_store_outlets, admin_create/update/delete_outlet
--   ab_variants       → create_profile trigger only
--   admins            → is_admin() only — most sensitive table, never directly queryable

GRANT SELECT ON public.profiles           TO authenticated;
GRANT SELECT ON public.stores             TO authenticated;
GRANT SELECT ON public.store_managers     TO authenticated;
GRANT SELECT ON public.store_staff        TO authenticated;
GRANT SELECT ON public.store_reward_rules TO authenticated;
GRANT SELECT ON public.points_ledger      TO authenticated;

-- ── 5. Function EXECUTE grants to authenticated ───────────────────────────────
-- Dynamic DO block reads pg_proc so no function signature needs to be listed
-- here manually. This means adding a new function and re-running this file is
-- all that's needed — no per-function GRANT line required.

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT proname, pg_get_function_identity_arguments(oid) AS args
    FROM   pg_proc
    WHERE  pronamespace = 'public'::regnamespace
      AND  prokind      = 'f'
  LOOP
    EXECUTE format(
      'GRANT EXECUTE ON FUNCTION public.%I(%s) TO authenticated',
      r.proname, r.args
    );
  END LOOP;
END $$;

-- ── 6. View grant ─────────────────────────────────────────────────────────────
-- PostgreSQL grants SELECT on a view to PUBLIC by default in some versions.

REVOKE ALL    ON public.admin_user_directory FROM anon, PUBLIC;
GRANT  SELECT ON public.admin_user_directory TO authenticated;

-- ── After running this file ───────────────────────────────────────────────────
-- Insert your admin user:
--   INSERT INTO public.admins (user_id) VALUES ('<your-auth-uid>');
-- Find your user_id in: Supabase Dashboard → Authentication → Users.
--
-- Verify no anon/PUBLIC grants remain:
--   SELECT routine_name, grantee, privilege_type
--   FROM   information_schema.role_routine_grants
--   WHERE  routine_schema = 'public'
--     AND  grantee IN ('anon', 'PUBLIC')
--   ORDER  BY routine_name;
