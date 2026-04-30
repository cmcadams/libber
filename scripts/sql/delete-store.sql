-- Delete a single store and all related data.
-- Run in the Supabase SQL editor (Dashboard → SQL Editor).
-- Set v_store_id to the store's UUID before running.

DO $$
DECLARE
  v_store_id uuid := 'REPLACE_WITH_STORE_ID';
  n int;
BEGIN
  DELETE FROM points_ledger          WHERE store_id = v_store_id; GET DIAGNOSTICS n = ROW_COUNT; RAISE NOTICE 'points_ledger:          %', n;
  DELETE FROM store_memberships      WHERE store_id = v_store_id; GET DIAGNOSTICS n = ROW_COUNT; RAISE NOTICE 'store_memberships:      %', n;
  DELETE FROM store_staff            WHERE store_id = v_store_id; GET DIAGNOSTICS n = ROW_COUNT; RAISE NOTICE 'store_staff:            %', n;
  DELETE FROM store_managers         WHERE store_id = v_store_id; GET DIAGNOSTICS n = ROW_COUNT; RAISE NOTICE 'store_managers:         %', n;
  DELETE FROM store_reward_rules     WHERE store_id = v_store_id; GET DIAGNOSTICS n = ROW_COUNT; RAISE NOTICE 'store_reward_rules:     %', n;
  DELETE FROM stores                 WHERE id        = v_store_id; GET DIAGNOSTICS n = ROW_COUNT; RAISE NOTICE 'stores:                 %', n;

  IF n = 0 THEN
    RAISE WARNING 'No store found with id %', v_store_id;
  ELSE
    RAISE NOTICE 'Done. Store % deleted.', v_store_id;
  END IF;
END $$;
