-- 20-grant-authenticated-select.sql
--
-- Grants SELECT to the authenticated role on the exact tables that client
-- code queries directly via supabase.from(...).
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
-- Scope — only tables with confirmed direct client queries (grep src/):
--   profiles           adminContext.js: supabase.from('profiles')
--   stores             admin.js: supabase.from('stores')
--   store_managers     admin.js, staff.js, adminContext.js: supabase.from('store_managers')
--   store_staff        admin.js, staff.js: supabase.from('store_staff')
--   store_reward_rules admin.js: supabase.from('store_reward_rules')
--   points_ledger      (realtime subscription + direct select)
--
-- NOT granted (accessed only via SECURITY DEFINER RPCs, never directly):
--   store_memberships  → load_customer_home, join_store, unjoin_store
--   store_outlets      → load_store_outlets, admin_create/update/delete_outlet
--   ab_variants        → create_profile trigger only
--   admins             → is_admin() only — most sensitive table, must not be
--                        directly queryable by authenticated clients even with
--                        RLS in place (least-privilege principle)
--
-- What this grants:
--   SELECT only. All writes go through SECURITY DEFINER RPCs.
--   RESTRICTIVE RLS policies block any direct INSERT/UPDATE/DELETE from clients.
--   RLS still controls which rows each role can read.
--
-- Depends on: 00-base-schema.sql (all six tables exist by this point)
-- Safe to re-run: yes — GRANT is idempotent.
-- Does NOT need 15-final-grants.sql re-run.

GRANT SELECT ON public.profiles           TO authenticated;
GRANT SELECT ON public.stores             TO authenticated;
GRANT SELECT ON public.store_managers     TO authenticated;
GRANT SELECT ON public.store_staff        TO authenticated;
GRANT SELECT ON public.store_reward_rules TO authenticated;
GRANT SELECT ON public.points_ledger      TO authenticated;
