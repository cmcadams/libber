-- admin_load_store_members: returns user_ids of all members of a store.
-- Used by the local-only admin tool to scope assignment candidate lists.
-- SECURITY DEFINER bypasses the "select own" RLS on store_memberships.
-- Run in the Supabase SQL Editor (Dashboard → SQL Editor).

CREATE OR REPLACE FUNCTION public.admin_load_store_members(p_store_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;

  RETURN (
    SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)
    FROM (
      SELECT user_id
      FROM   public.store_memberships
      WHERE  store_id = p_store_id
    ) t
  );
END;
$$;
