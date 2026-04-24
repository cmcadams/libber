-- SELECT RLS policies for all tables read directly by the client.
-- All write paths already go through SECURITY DEFINER RPCs with their own auth checks.
-- Safe to re-run — all statements are idempotent.
-- Run in the Supabase SQL Editor (Dashboard → SQL Editor).

-- ── profiles ──────────────────────────────────────────────────────────────────
-- RLS not previously enabled on this table.
-- public_id is intentionally shareable (shown to staff via Show Staff feature).
-- USING (true) allows manager tools to resolve names for their staff members.

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "profiles: allow select" ON public.profiles;
CREATE POLICY "profiles: allow select" ON public.profiles
  FOR SELECT USING (true);

-- ── store_managers ────────────────────────────────────────────────────────────
-- RLS not previously enabled on this table.
-- Managers see only their own records; admins see all.
-- SECURITY DEFINER RPCs (approve_staff_applicant etc.) bypass this via superuser role.

ALTER TABLE public.store_managers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "managers: no direct insert" ON public.store_managers;
DROP POLICY IF EXISTS "managers: no direct delete" ON public.store_managers;
DROP POLICY IF EXISTS "managers: allow select"    ON public.store_managers;

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

DROP POLICY IF EXISTS "staff: allow select" ON public.store_staff;
CREATE POLICY "staff: allow select" ON public.store_staff
  FOR SELECT USING (true);

-- ── store_staff_applicants ────────────────────────────────────────────────────
-- Managers need to see all applicants for their store; users need their own.
-- Using true — application status is not sensitive personal data.

DROP POLICY IF EXISTS "applicants: allow select" ON public.store_staff_applicants;
CREATE POLICY "applicants: allow select" ON public.store_staff_applicants
  FOR SELECT USING (true);
