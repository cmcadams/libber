-- 11-security-hardening.sql
--
-- Security hardening: Realtime, scoped RLS policies, function/table grants.
-- Based on harden-rls-and-grants.sql with section 3 removed:
--   Section 3 (store_staff_applicants scoped SELECT policies) is omitted because
--   the applicant system is fully removed — the table does not exist in the rebuild.
--
-- Changes captured:
--   1. Realtime — added points_ledger to supabase_realtime publication.
--   2. profiles — replaced global SELECT with own-row-only read.
--   3. [REMOVED — store_staff_applicants does not exist in this rebuild]
--   4. store_staff — replaced global SELECT with scoped reads
--      (self + manager-of-store + admin).
--   5. Function grants — revoked anon/PUBLIC execute on all RPCs;
--      re-granted explicitly to authenticated.
--   6. Table/sequence grants — revoked all anon grants; set default
--      privileges to prevent future broad grants.
--
-- Safe to re-run. DROP IF EXISTS before every CREATE; REVOKE is idempotent.
-- Run in Supabase SQL Editor (Dashboard → SQL Editor).

-- ── 1. Realtime ───────────────────────────────────────────────────────────────

ALTER PUBLICATION supabase_realtime ADD TABLE public.points_ledger;

-- ── 2. profiles: own-row-only SELECT ─────────────────────────────────────────
-- Previous: USING (true) — any authenticated user could read any profile.
-- SECURITY DEFINER RPCs (load_store_members, load_store_staff_profiles,
-- load_customer_home) are unaffected — they bypass RLS via the definer role.

DROP POLICY IF EXISTS "profiles: allow select" ON public.profiles;
DROP POLICY IF EXISTS "profiles: select own"   ON public.profiles;

CREATE POLICY "profiles: select own" ON public.profiles
  FOR SELECT USING (auth.uid() = user_id);

-- ── 3. [SKIPPED — store_staff_applicants not in rebuild] ──────────────────────

-- ── 4. store_staff: scoped SELECT ─────────────────────────────────────────────
-- Previous: USING (true) — any authenticated user could read all staff rows.
-- New: self / manager-of-store / admin.

DROP POLICY IF EXISTS "staff: allow select"       ON public.store_staff;
DROP POLICY IF EXISTS "staff: select self"        ON public.store_staff;
DROP POLICY IF EXISTS "staff: select as manager"  ON public.store_staff;
DROP POLICY IF EXISTS "staff: select as admin"    ON public.store_staff;

CREATE POLICY "staff: select self" ON public.store_staff
  FOR SELECT USING (user_id = auth.uid());

CREATE POLICY "staff: select as manager" ON public.store_staff
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.store_managers
      WHERE store_id = store_staff.store_id
        AND user_id  = auth.uid()
    )
  );

CREATE POLICY "staff: select as admin" ON public.store_staff
  FOR SELECT USING (public.is_admin());

-- ── 5. Function execute grants ────────────────────────────────────────────────
-- PostgreSQL grants EXECUTE to PUBLIC by default on new functions.
-- Revoke that blanket grant, then re-grant only to authenticated.
-- anon role (unauthenticated requests) should never call any RPC in this app.

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM anon, PUBLIC;

-- Re-grant to authenticated. Using a DO block avoids hard-coding every
-- function signature — it reads from pg_proc and grants dynamically.
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

-- ── 6. Table and sequence grants ──────────────────────────────────────────────
-- Remove anon-role grants on all existing tables/sequences.
-- RLS governs row access; the anon role should hold no table privileges at all.

REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM anon;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon;

-- Prevent future objects from inheriting broad grants automatically.
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES    FROM anon, PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon, PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM anon, PUBLIC;
