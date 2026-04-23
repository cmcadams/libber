-- Adds reject_staff_applicant RPC so managers can reject applicants.
-- Follows the same pattern as approve_staff_applicant and demote_store_staff.
-- Run in the Supabase SQL Editor (Dashboard → SQL Editor).

CREATE OR REPLACE FUNCTION public.reject_staff_applicant(p_user_id uuid, p_store_id uuid)
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

  DELETE FROM public.store_staff_applicants
  WHERE user_id = p_user_id AND store_id = p_store_id;

  RETURN json_build_object('success', true, 'user_id', p_user_id, 'store_id', p_store_id);
END $$;
