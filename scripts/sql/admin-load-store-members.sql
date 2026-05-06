-- admin_load_store_members: returns user_ids of members of a store.
-- Caller must be a manager of the requested store (enforced at DB level).
-- SECURITY DEFINER bypasses the "select own" RLS on store_memberships;
-- the EXISTS clause re-establishes tenant-scoped authorization explicitly.
-- Unauthorized callers (wrong store, not a manager, anon) get zero rows.
-- Run in the Supabase SQL Editor (Dashboard → SQL Editor).

CREATE OR REPLACE FUNCTION public.admin_load_store_members(p_store_id uuid)
RETURNS TABLE(user_id uuid)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT sm.user_id
  FROM   public.store_memberships sm
  WHERE  sm.store_id = p_store_id
    AND  EXISTS (
           SELECT 1
           FROM   public.store_managers m
           WHERE  m.user_id  = auth.uid()
             AND  m.store_id = p_store_id
         );
$$;
