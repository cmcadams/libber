-- Full reset: deletes ALL data from every table including auth users.
-- Run in the Supabase SQL editor (Dashboard → SQL Editor).
-- There is no undo. Export a backup first if needed (npm run cleanup:export).

DO $$
DECLARE
  n int;
BEGIN
  DELETE FROM points_ledger;          GET DIAGNOSTICS n = ROW_COUNT; RAISE NOTICE 'points_ledger:          %', n;
  DELETE FROM store_memberships;      GET DIAGNOSTICS n = ROW_COUNT; RAISE NOTICE 'store_memberships:      %', n;
  DELETE FROM store_staff;            GET DIAGNOSTICS n = ROW_COUNT; RAISE NOTICE 'store_staff:            %', n;
  DELETE FROM store_managers;         GET DIAGNOSTICS n = ROW_COUNT; RAISE NOTICE 'store_managers:         %', n;
  DELETE FROM store_staff_applicants; GET DIAGNOSTICS n = ROW_COUNT; RAISE NOTICE 'store_staff_applicants: %', n;
  DELETE FROM store_reward_rules;     GET DIAGNOSTICS n = ROW_COUNT; RAISE NOTICE 'store_reward_rules:     %', n;
  DELETE FROM stores;                 GET DIAGNOSTICS n = ROW_COUNT; RAISE NOTICE 'stores:                 %', n;
  DELETE FROM profiles;               GET DIAGNOSTICS n = ROW_COUNT; RAISE NOTICE 'profiles:               %', n;
  DELETE FROM auth.users;             GET DIAGNOSTICS n = ROW_COUNT; RAISE NOTICE 'auth.users:             %', n;

  RAISE NOTICE 'Done. System is clean.';
END $$;
