-- admin_load_store_members: returns user_ids of all members of a store.
-- Used by the local-only admin tool to scope assignment candidate lists.
-- SECURITY DEFINER bypasses the "select own" RLS on store_memberships.
-- Auth protection relies on GRANT EXECUTE to authenticated role only.
-- Run in the Supabase SQL Editor (Dashboard → SQL Editor).

CREATE OR REPLACE FUNCTION public.admin_load_store_members(p_store_id uuid)
RETURNS TABLE(user_id uuid)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT sm.user_id
  FROM   public.store_memberships sm
  WHERE  sm.store_id = p_store_id;
$$;
