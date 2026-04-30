-- Remove applicant-table DELETE statements from three RPCs.
-- Run in the Supabase SQL Editor (Dashboard → SQL Editor).
-- Safe to re-run — all statements are CREATE OR REPLACE / idempotent.
--
-- Background: the apply-to-store system has been removed from all frontends.
-- These three RPCs previously cleaned up applicant rows as a side effect of
-- promoting staff, assigning managers, or deleting a store. Those DELETEs are
-- removed here so store_staff_applicants and store_manager_applicants can be
-- dropped in the next step. All other business logic is unchanged.

-- ── approve_staff_applicant ───────────────────────────────────────────────────
-- Change: removed DELETE FROM store_staff_applicants (was cleanup after INSERT).

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
  IF p_user_id IS NULL    THEN RAISE EXCEPTION 'missing user_id'; END IF;
  IF p_store_id IS NULL   THEN RAISE EXCEPTION 'missing store_id'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.store_managers
    WHERE user_id = v_manager_id AND store_id = p_store_id
  ) THEN
    RAISE EXCEPTION 'not authorized for this store';
  END IF;

  INSERT INTO public.store_staff (user_id, store_id)
  VALUES (p_user_id, p_store_id)
  ON CONFLICT DO NOTHING;

  RETURN json_build_object('success', true, 'user_id', p_user_id, 'store_id', p_store_id);
END $$;

-- ── admin_assign_manager ──────────────────────────────────────────────────────
-- Change: removed DELETE FROM store_manager_applicants (was cleanup after INSERT).

DROP FUNCTION IF EXISTS public.admin_assign_manager(uuid, uuid);
CREATE OR REPLACE FUNCTION public.admin_assign_manager(p_user_id uuid, p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  INSERT INTO public.store_managers (user_id, store_id) VALUES (p_user_id, p_store_id)
  ON CONFLICT DO NOTHING;
END $$;

-- ── admin_remove_store ────────────────────────────────────────────────────────
-- Change: removed DELETE FROM store_staff_applicants and store_manager_applicants.

CREATE OR REPLACE FUNCTION public.admin_remove_store(p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  DELETE FROM public.points_ledger      WHERE store_id = p_store_id;
  DELETE FROM public.store_memberships  WHERE store_id = p_store_id;
  DELETE FROM public.store_staff        WHERE store_id = p_store_id;
  DELETE FROM public.store_managers     WHERE store_id = p_store_id;
  DELETE FROM public.store_reward_rules WHERE store_id = p_store_id;
  DELETE FROM public.stores             WHERE id        = p_store_id;
END $$;
