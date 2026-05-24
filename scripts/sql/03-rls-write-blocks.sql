-- 03-rls-write-blocks.sql
--
-- Staff and member RPC write blocks and RPCs.
-- Based on staff-rpcs.sql with the following changes for the clean rebuild:
--   - store_staff_applicants RLS block removed (table does not exist)
--   - apply_for_staff removed (applicant system fully removed)
--   - approve_staff_applicant v1 removed (referenced store_staff_applicants;
--     clean version with RBAC helpers is in 14-soft-delete.sql)
--
-- Safe to re-run — all statements are idempotent.
-- Run in the Supabase SQL Editor (Dashboard → SQL Editor).

-- ── Ensure RLS is enabled ─────────────────────────────────────────────────────

ALTER TABLE public.store_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_staff       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.points_ledger     ENABLE ROW LEVEL SECURITY;

-- ── RLS: block direct writes to store_memberships ────────────────────────────

DROP POLICY IF EXISTS "memberships: no direct insert" ON public.store_memberships;

CREATE POLICY "memberships: no direct insert" ON public.store_memberships
  AS RESTRICTIVE FOR INSERT WITH CHECK (false);

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
-- Early version — overwritten by 14-soft-delete.sql with is_active support.

CREATE OR REPLACE FUNCTION public.join_store(p_store_id uuid)
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

  INSERT INTO public.store_memberships (user_id, store_id)
  VALUES (v_user_id, p_store_id)
  ON CONFLICT (user_id, store_id) DO NOTHING;

  RETURN json_build_object('success', true, 'user_id', v_user_id, 'store_id', p_store_id);
END $$;

-- ── demote_store_staff ────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.demote_store_staff(uuid, uuid);
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

-- award_points is defined in add-bonus-cap.sql (authoritative version with cap logic).
