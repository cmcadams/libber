-- load_member_recent_transactions RPC: returns the last 5 ledger entries for a
-- specific member, scoped to a store. Caller must be staff or manager of the store.
-- Safe to re-run (CREATE OR REPLACE).
-- Run in the Supabase SQL Editor (Dashboard → SQL Editor).

CREATE OR REPLACE FUNCTION public.load_member_recent_transactions(
  p_user_id  uuid,
  p_store_id uuid
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.store_staff    WHERE user_id = auth.uid() AND store_id = p_store_id
    UNION ALL
    SELECT 1 FROM public.store_managers WHERE user_id = auth.uid() AND store_id = p_store_id
  ) THEN
    RAISE EXCEPTION 'not authorized for this store';
  END IF;

  RETURN (
    SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)
    FROM (
      SELECT points, reason, created_at
      FROM   public.points_ledger
      WHERE  user_id  = p_user_id
        AND  store_id = p_store_id
      ORDER  BY created_at DESC
      LIMIT  5
    ) t
  );
END;
$$;
