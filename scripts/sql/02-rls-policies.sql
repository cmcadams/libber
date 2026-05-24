-- 02-rls-policies.sql
--
-- SELECT RLS policies for all tables read directly by the client.
-- Based on add-rls-select-policies.sql with store_staff_applicants block removed
-- (applicant system fully removed from rebuild).
--
-- All write paths go through SECURITY DEFINER RPCs with their own auth checks.
-- Safe to re-run — all statements are idempotent.
-- Run in the Supabase SQL Editor (Dashboard → SQL Editor).

-- ── profiles ──────────────────────────────────────────────────────────────────
-- public_id is intentionally shareable (shown to staff via Show Staff feature).
-- USING (true) allows manager tools to resolve names for their staff members.
-- (Narrowed to own-row-only in 11-security-hardening.sql)

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "profiles: allow select" ON public.profiles;
CREATE POLICY "profiles: allow select" ON public.profiles
  FOR SELECT USING (true);

-- ── store_managers ────────────────────────────────────────────────────────────
-- Managers see only their own records; admins see all.
-- SECURITY DEFINER RPCs bypass this via superuser role.

ALTER TABLE public.store_managers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "managers: no direct insert" ON public.store_managers;
DROP POLICY IF EXISTS "managers: no direct delete" ON public.store_managers;
DROP POLICY IF EXISTS "managers: allow select"     ON public.store_managers;

CREATE POLICY "managers: no direct insert" ON public.store_managers
  AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY "managers: no direct delete" ON public.store_managers
  AS RESTRICTIVE FOR DELETE USING (false);
CREATE POLICY "managers: allow select" ON public.store_managers
  FOR SELECT USING (user_id = auth.uid() OR public.is_admin());

-- ── store_memberships ─────────────────────────────────────────────────────────
-- Each user can only read their own memberships.
-- Required for loadUserStoresWithPoints (called after a store join).

DROP POLICY IF EXISTS "memberships: select own" ON public.store_memberships;
CREATE POLICY "memberships: select own" ON public.store_memberships
  FOR SELECT USING (user_id = auth.uid());

-- ── points_ledger ─────────────────────────────────────────────────────────────
-- Each user can only read their own ledger rows.
-- Also enforces Realtime subscription filtering (postgres_changes respects RLS).

DROP POLICY IF EXISTS "ledger: select own" ON public.points_ledger;
CREATE POLICY "ledger: select own" ON public.points_ledger
  FOR SELECT USING (user_id = auth.uid());

-- ── store_reward_rules ────────────────────────────────────────────────────────
-- Rules are not sensitive — any authenticated user can read them.
-- Required for customer "How to earn" section and staff award buttons.

DROP POLICY IF EXISTS "rules: allow select" ON public.store_reward_rules;
CREATE POLICY "rules: allow select" ON public.store_reward_rules
  FOR SELECT USING (true);

-- ── store_staff ───────────────────────────────────────────────────────────────
-- Any authenticated user can see who is staff (user_id only, not personal data).
-- Required for manager staff list and staff store lookup.
-- (Narrowed to scoped reads in 11-security-hardening.sql)

DROP POLICY IF EXISTS "staff: allow select" ON public.store_staff;
CREATE POLICY "staff: allow select" ON public.store_staff
  FOR SELECT USING (true);
