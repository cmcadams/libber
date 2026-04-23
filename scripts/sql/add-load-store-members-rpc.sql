-- load_store_members RPC: returns members with balances and public IDs.
-- Caller must be staff of the store. Bypasses profiles RLS via SECURITY DEFINER.
-- Run in the Supabase SQL Editor (Dashboard → SQL Editor).

CREATE OR REPLACE FUNCTION public.load_store_members(p_store_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.store_staff
    WHERE user_id = auth.uid() AND store_id = p_store_id
    UNION
    SELECT 1 FROM public.store_managers
    WHERE user_id = auth.uid() AND store_id = p_store_id
  ) THEN
    RAISE EXCEPTION 'not authorized: not staff or manager for this store';
  END IF;

  RETURN (
    SELECT json_agg(row_to_json(t))
    FROM (
      SELECT
        sm.user_id,
        p.public_id,
        COALESCE(
          (SELECT running_balance
           FROM public.points_ledger pl
           WHERE pl.user_id = sm.user_id AND pl.store_id = p_store_id
           ORDER BY pl.created_at DESC
           LIMIT 1),
          0
        ) AS balance
      FROM public.store_memberships sm
      LEFT JOIN public.profiles p ON p.user_id = sm.user_id
      WHERE sm.store_id = p_store_id
    ) t
  );
END $$;
