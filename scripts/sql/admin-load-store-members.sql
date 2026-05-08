-- admin_load_store_members: returns user_ids of members of a store.
-- Caller must be a global admin OR a manager of the requested store.
-- SECURITY DEFINER bypasses the "select own" RLS on store_memberships;
-- the WHERE clause re-establishes authorization explicitly.
-- Unauthorized callers (wrong store, not a manager, not admin, anon) get zero rows.
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
    AND  (
           public.is_admin()
           OR EXISTS (
             SELECT 1
             FROM   public.store_managers m
             WHERE  m.user_id  = auth.uid()
               AND  m.store_id = p_store_id
           )
         );
$$;
