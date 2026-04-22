-- Staff and member RPC hardening.
-- Safe to re-run — all statements are idempotent.
-- Run in the Supabase SQL Editor (Dashboard → SQL Editor).
--
-- Applies the same pattern as admin-rpcs.sql to the remaining write tables:
--   - store_memberships    (join_store)
--   - store_staff_applicants (apply_for_staff, approve_staff_applicant)
--   - store_staff          (approve_staff_applicant, demote_store_staff)
--   - points_ledger        (award_points)
--
-- All five existing RPCs are rewritten as SECURITY DEFINER so they bypass
-- the new RESTRICTIVE blocks. Logic is preserved exactly.

-- ── Ensure RLS is enabled ─────────────────────────────────────────────────────

ALTER TABLE public.store_memberships      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_staff_applicants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_staff            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.points_ledger          ENABLE ROW LEVEL SECURITY;

-- ── RLS: block direct writes to store_memberships ────────────────────────────

DROP POLICY IF EXISTS "memberships: no direct insert" ON public.store_memberships;

CREATE POLICY "memberships: no direct insert" ON public.store_memberships
  AS RESTRICTIVE FOR INSERT WITH CHECK (false);

-- ── RLS: block direct writes to store_staff_applicants ───────────────────────

DROP POLICY IF EXISTS "applicants: no direct insert" ON public.store_staff_applicants;
DROP POLICY IF EXISTS "applicants: no direct delete" ON public.store_staff_applicants;

CREATE POLICY "applicants: no direct insert" ON public.store_staff_applicants
  AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY "applicants: no direct delete" ON public.store_staff_applicants
  AS RESTRICTIVE FOR DELETE USING (false);

-- ── RLS: block direct writes to store_staff ──────────────────────────────────

DROP POLICY IF EXISTS "staff: no direct insert" ON public.store_staff;
DROP POLICY IF EXISTS "staff: no direct delete" ON public.store_staff;

CREATE POLICY "staff: no direct insert" ON public.store_staff
  AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY "staff: no direct delete" ON public.store_staff
  AS RESTRICTIVE FOR DELETE USING (false);

-- ── RLS: block direct insert to points_ledger ────────────────────────────────

DROP POLICY IF EXISTS "ledger: no direct insert" ON public.points_ledger;

CREATE POLICY "ledger: no direct insert" ON public.points_ledger
  AS RESTRICTIVE FOR INSERT WITH CHECK (false);

-- ── join_store ────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.join_store(p_store_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid;
  v_result  json;
BEGIN
  v_user_id := auth.uid();

  IF v_user_id IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_store_id IS NULL THEN RAISE EXCEPTION 'missing store_id'; END IF;

  INSERT INTO public.store_memberships (user_id, store_id)
  VALUES (v_user_id, p_store_id)
  ON CONFLICT (user_id, store_id) DO NOTHING;

  SELECT json_build_object('success', true, 'user_id', v_user_id, 'store_id', p_store_id)
  INTO v_result;

  RETURN v_result;
END $$;

-- ── apply_for_staff ───────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.apply_for_staff(p_store_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  v_user_id := auth.uid();

  IF v_user_id IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_store_id IS NULL THEN RAISE EXCEPTION 'missing store_id'; END IF;

  INSERT INTO public.store_staff_applicants (user_id, store_id)
  VALUES (v_user_id, p_store_id)
  ON CONFLICT (user_id, store_id) DO NOTHING;

  RETURN json_build_object('success', true, 'user_id', v_user_id, 'store_id', p_store_id);
END $$;

-- ── approve_staff_applicant ───────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.approve_staff_applicant(p_user_id uuid, p_store_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_manager_id uuid;
BEGIN
  v_manager_id := auth.uid();

  IF v_manager_id IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_user_id IS NULL   THEN RAISE EXCEPTION 'missing user_id'; END IF;
  IF p_store_id IS NULL  THEN RAISE EXCEPTION 'missing store_id'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.store_managers
    WHERE user_id = v_manager_id AND store_id = p_store_id
  ) THEN
    RAISE EXCEPTION 'not authorized for this store';
  END IF;

  INSERT INTO public.store_staff (user_id, store_id)
  VALUES (p_user_id, p_store_id)
  ON CONFLICT DO NOTHING;

  DELETE FROM public.store_staff_applicants
  WHERE user_id = p_user_id AND store_id = p_store_id;

  RETURN json_build_object('success', true, 'user_id', p_user_id, 'store_id', p_store_id);
END $$;

-- ── demote_store_staff ────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.demote_store_staff(p_user_id uuid, p_store_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_manager_id uuid;
BEGIN
  v_manager_id := auth.uid();

  IF v_manager_id IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_store_id IS NULL   THEN RAISE EXCEPTION 'missing store_id'; END IF;
  IF p_user_id IS NULL    THEN RAISE EXCEPTION 'missing user_id'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.store_managers
    WHERE user_id = v_manager_id AND store_id = p_store_id
  ) THEN
    RAISE EXCEPTION 'not authorized for this store';
  END IF;

  DELETE FROM public.store_staff
  WHERE user_id = p_user_id AND store_id = p_store_id;

  RETURN json_build_object('success', true, 'user_id', p_user_id, 'store_id', p_store_id);
END $$;

-- ── award_points ──────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.award_points(
  p_user_id  uuid,
  p_store_id uuid,
  p_points   integer,
  p_reason   text
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_staff_id        uuid;
  v_current_balance integer;
  v_new_balance     integer;
BEGIN
  v_staff_id := auth.uid();

  IF v_staff_id IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.store_staff
    WHERE user_id = v_staff_id AND store_id = p_store_id
  ) THEN
    RAISE EXCEPTION 'not authorized: not staff for this store';
  END IF;

  IF p_points = 0 THEN RAISE EXCEPTION 'points cannot be zero'; END IF;

  SELECT running_balance INTO v_current_balance
  FROM public.points_ledger
  WHERE user_id = p_user_id AND store_id = p_store_id
  ORDER BY created_at DESC
  LIMIT 1;

  v_current_balance := coalesce(v_current_balance, 0);
  v_new_balance     := v_current_balance + p_points;

  INSERT INTO public.points_ledger (user_id, store_id, points, reason, created_by, running_balance)
  VALUES (p_user_id, p_store_id, p_points, p_reason, v_staff_id, v_new_balance);

  RETURN v_new_balance;
END $$;
