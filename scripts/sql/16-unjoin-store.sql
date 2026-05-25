-- 16-unjoin-store.sql
--
-- Adds unjoin_store(p_store_id uuid) → json.
-- Soft-removes the caller's membership by setting is_active = false.
-- Mirror of join_store (14-soft-delete.sql) which sets is_active = true.
--
-- Called by src/services/stores.js unjoinStore() — was missing from the
-- canonical rebuild chain, causing a hard RPC error for any customer
-- who tapped unjoin.
--
-- Does not call assert_store_active: customers can leave archived stores
-- (they can't see them anyway, but allowing it is harmless and idempotent).
--
-- Safe to re-run: yes (CREATE OR REPLACE).
-- Re-run 15-final-grants.sql after this.

CREATE OR REPLACE FUNCTION public.unjoin_store(p_store_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id  IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_store_id IS NULL THEN RAISE EXCEPTION 'missing store_id';  END IF;

  UPDATE public.store_memberships
  SET    is_active = false
  WHERE  user_id  = v_user_id
    AND  store_id = p_store_id;

  RETURN json_build_object('success', true, 'user_id', v_user_id, 'store_id', p_store_id);
END $$;

GRANT EXECUTE ON FUNCTION public.unjoin_store(uuid) TO authenticated;
