-- Delete a single user and all their data.
-- Run in the Supabase SQL editor (Dashboard → SQL Editor).
-- Set v_public_id to the user's human-readable ID (shown in the admin tool).
-- Note: deleting from auth.users requires the SQL editor (runs as postgres superuser).

DO $$
DECLARE
  v_public_id text := 'REPLACE_WITH_PUBLIC_ID';
  v_user_id   uuid;
  n           int;
BEGIN
  SELECT user_id INTO v_user_id FROM public.profiles WHERE public_id = v_public_id;
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'No user found with public_id %', v_public_id; END IF;

  DELETE FROM points_ledger          WHERE user_id = v_user_id; GET DIAGNOSTICS n = ROW_COUNT; RAISE NOTICE 'points_ledger:          %', n;
  DELETE FROM store_memberships      WHERE user_id = v_user_id; GET DIAGNOSTICS n = ROW_COUNT; RAISE NOTICE 'store_memberships:      %', n;
  DELETE FROM store_staff            WHERE user_id = v_user_id; GET DIAGNOSTICS n = ROW_COUNT; RAISE NOTICE 'store_staff:            %', n;
  DELETE FROM store_managers         WHERE user_id = v_user_id; GET DIAGNOSTICS n = ROW_COUNT; RAISE NOTICE 'store_managers:         %', n;
  DELETE FROM store_staff_applicants    WHERE user_id = v_user_id; GET DIAGNOSTICS n = ROW_COUNT; RAISE NOTICE 'store_staff_applicants:    %', n;
  DELETE FROM store_manager_applicants  WHERE user_id = v_user_id; GET DIAGNOSTICS n = ROW_COUNT; RAISE NOTICE 'store_manager_applicants:  %', n;
  DELETE FROM profiles               WHERE user_id = v_user_id; GET DIAGNOSTICS n = ROW_COUNT; RAISE NOTICE 'profiles:               %', n;
  DELETE FROM auth.users             WHERE id       = v_user_id; GET DIAGNOSTICS n = ROW_COUNT; RAISE NOTICE 'auth.users:             %', n;

  RAISE NOTICE 'Done. User % deleted.', v_public_id;
END $$;
