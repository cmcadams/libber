-- fix-default-privileges.sql
--
-- Re-revokes anon/PUBLIC execute on all public functions and re-grants
-- to authenticated only.
--
-- Needed because CREATE OR REPLACE FUNCTION re-applies default privileges,
-- which can restore broad grants when supabase_admin's global defaults include
-- anon/PUBLIC. Those defaults cannot be changed from the SQL Editor (postgres
-- is not superuser), so re-running this script after any migration that
-- creates or replaces functions is the mitigation.
--
-- Table and sequence grants are not affected by CREATE OR REPLACE FUNCTION
-- and are already locked down by harden-rls-and-grants.sql.
--
-- Safe to re-run. Run in Supabase SQL Editor (Dashboard → SQL Editor).

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM anon, PUBLIC;

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

-- ── Verify ────────────────────────────────────────────────────────────────────
-- anon and PUBLIC should return zero rows:
--   SELECT routine_name, grantee, privilege_type
--   FROM information_schema.role_routine_grants
--   WHERE routine_schema = 'public'
--     AND grantee IN ('anon', 'PUBLIC')
--   ORDER BY routine_name;
