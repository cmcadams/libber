-- load_customer_home RPC: returns profile + memberships with balances + all stores in one round trip.
-- Safe to re-run — uses CREATE OR REPLACE.
-- Run in the Supabase SQL Editor (Dashboard → SQL Editor).

CREATE OR REPLACE FUNCTION public.load_customer_home()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;

  RETURN json_build_object(
    'public_id', (
      SELECT public_id FROM public.profiles WHERE user_id = v_user_id
    ),
    'memberships', (
      SELECT COALESCE(json_agg(json_build_object(
        'store_id', sm.store_id,
        'store_name', s.name,
        'balance', COALESCE((
          SELECT running_balance
          FROM public.points_ledger
          WHERE user_id = v_user_id AND store_id = sm.store_id
          ORDER BY created_at DESC
          LIMIT 1
        ), 0)
      )), '[]'::json)
      FROM public.store_memberships sm
      JOIN public.stores s ON s.id = sm.store_id
      WHERE sm.user_id = v_user_id
    ),
    'stores', (
      SELECT COALESCE(json_agg(json_build_object('id', id, 'name', name)), '[]'::json)
      FROM public.stores
    )
  );
END $$;
