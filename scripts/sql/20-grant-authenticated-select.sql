-- 20-grant-authenticated-select.sql
--
-- Grants SELECT to the authenticated role on all tables that client code
-- queries directly via supabase.from(...).
--
-- Root cause:
--   11-security-hardening.sql ran:
--     ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM anon, PUBLIC;
--   In Supabase, the SELECT grant to authenticated was inherited from PUBLIC,
--   not granted explicitly to authenticated. Revoking PUBLIC therefore stripped
--   authenticated of SELECT on all tables — including profiles, stores, etc.
--   SECURITY DEFINER RPCs were unaffected (they run as postgres, which retains
--   all privileges), which is why RPCs kept working while direct table queries
--   started returning permission errors.
--
-- What this grants:
--   SELECT only. All writes continue to go through SECURITY DEFINER RPCs.
--   RESTRICTIVE RLS policies already block any direct INSERT/UPDATE/DELETE
--   attempt from the client, so those privileges are not needed here.
--
-- Row-level access is still fully controlled by RLS — this grant only
-- restores the table-level SELECT permission that was incorrectly stripped.
--
-- Depends on: 00-base-schema.sql through 07-schema-ab-testing.sql (all tables)
-- Safe to re-run: yes — GRANT is idempotent.
-- Does NOT need 15-final-grants.sql re-run.

GRANT SELECT ON public.profiles           TO authenticated;
GRANT SELECT ON public.stores             TO authenticated;
GRANT SELECT ON public.store_memberships  TO authenticated;
GRANT SELECT ON public.store_staff        TO authenticated;
GRANT SELECT ON public.store_managers     TO authenticated;
GRANT SELECT ON public.store_reward_rules TO authenticated;
GRANT SELECT ON public.points_ledger      TO authenticated;
GRANT SELECT ON public.store_outlets      TO authenticated;
GRANT SELECT ON public.ab_variants        TO authenticated;
GRANT SELECT ON public.admins             TO authenticated;
