-- Security fix: approve_staff_applicant RPC.
-- Run in the Supabase SQL Editor (Dashboard → SQL Editor).
-- Safe to re-run (CREATE OR REPLACE, same signature).
--
-- Problem: after the applicant system was removed, this function lost its only
-- gate that confirmed the target user had opted in. It now accepts any UUID as
-- p_user_id and silently inserts it into store_staff. A manager calling the RPC
-- directly (not via the UI) could promote an arbitrary, non-member user to staff.
--
-- Fix: require the target user to already be a member of the store
-- (i.e. present in store_memberships) before allowing the promotion.
-- This preserves the "manager promotes a known, willing participant" semantic
-- without reintroducing any part of the applicant system.

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

  -- Guard added after applicant system removal: the target user must be a member
  -- of the store. Prevents a manager from promoting an arbitrary UUID to staff
  -- by calling this RPC directly without going through the UI.
  IF NOT EXISTS (
    SELECT 1 FROM public.store_memberships
    WHERE user_id = p_user_id AND store_id = p_store_id
  ) THEN
    RAISE EXCEPTION 'user is not a member of this store';
  END IF;

  INSERT INTO public.store_staff (user_id, store_id)
  VALUES (p_user_id, p_store_id)
  ON CONFLICT DO NOTHING;

  RETURN json_build_object('success', true, 'user_id', p_user_id, 'store_id', p_store_id);
END;
$$;
