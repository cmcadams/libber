-- Delete a single user and all their data.
-- Run in the Supabase SQL editor (Dashboard → SQL Editor).
-- Set v_user_id to the user's auth UUID before running.
-- Note: deleting from auth.users requires the SQL editor (runs as postgres superuser).

DO $$
DECLARE
  v_user_id uuid := 'REPLACE_WITH_USER_ID';
  n int;
BEGIN
  DELETE FROM points_ledger          WHERE user_id = v_user_id; GET DIAGNOSTICS n = ROW_COUNT; RAISE NOTICE 'points_ledger:          %', n;
  DELETE FROM store_memberships      WHERE user_id = v_user_id; GET DIAGNOSTICS n = ROW_COUNT; RAISE NOTICE 'store_memberships:      %', n;
  DELETE FROM store_staff            WHERE user_id = v_user_id; GET DIAGNOSTICS n = ROW_COUNT; RAISE NOTICE 'store_staff:            %', n;
  DELETE FROM store_managers         WHERE user_id = v_user_id; GET DIAGNOSTICS n = ROW_COUNT; RAISE NOTICE 'store_managers:         %', n;
  DELETE FROM store_staff_applicants WHERE user_id = v_user_id; GET DIAGNOSTICS n = ROW_COUNT; RAISE NOTICE 'store_staff_applicants: %', n;
  DELETE FROM profiles               WHERE user_id = v_user_id; GET DIAGNOSTICS n = ROW_COUNT; RAISE NOTICE 'profiles:               %', n;
  DELETE FROM auth.users             WHERE id       = v_user_id; GET DIAGNOSTICS n = ROW_COUNT; RAISE NOTICE 'auth.users:             %', n;

  IF n = 0 THEN
    RAISE WARNING 'No auth user found with id %', v_user_id;
  ELSE
    RAISE NOTICE 'Done. User % deleted.', v_user_id;
  END IF;
END $$;
