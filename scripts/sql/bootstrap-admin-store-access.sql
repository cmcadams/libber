-- Bootstrap: grant global admin full manager access to all existing stores.
--
-- What this does:
--   1. Resolves public_id 'MQH 335 484' to a user_id via public.profiles.
--   2. Inserts into public.admins (global admin identity) — idempotent.
--   3. Inserts one row per existing store into public.store_managers — idempotent.
--
-- Safe to re-run: ON CONFLICT DO NOTHING on both tables prevents duplicates.
-- Does NOT weaken RLS: store_managers RLS blocks direct writes from clients;
-- this script runs as the postgres superuser in the SQL Editor which bypasses
-- RLS by design. No policy is modified.
--
-- Run in: Supabase Dashboard → SQL Editor.

DO $$
DECLARE
  v_user_id     uuid;
  v_new_grants  int;
  v_total_stores int;
BEGIN

  -- 1. Resolve the admin's public_id to their internal user_id.
  SELECT user_id INTO v_user_id
  FROM   public.profiles
  WHERE  public_id = 'MQH 335 484';

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No profile found with public_id = ''MQH 335 484'' — verify the ID and retry.';
  END IF;

  -- 2. Add to global admins table (idempotent).
  INSERT INTO public.admins (user_id)
  VALUES (v_user_id)
  ON CONFLICT DO NOTHING;

  -- 3. Grant manager access to every existing store (idempotent).
  --    Only inserts rows for stores that exist; no phantom grants possible.
  SELECT COUNT(*) INTO v_total_stores FROM public.stores;

  INSERT INTO public.store_managers (user_id, store_id)
  SELECT v_user_id, s.id
  FROM   public.stores s
  ON CONFLICT DO NOTHING;

  GET DIAGNOSTICS v_new_grants = ROW_COUNT;

  RAISE NOTICE '------------------------------------------------------------';
  RAISE NOTICE 'Bootstrap complete.';
  RAISE NOTICE '  user_id      : %', v_user_id;
  RAISE NOTICE '  total stores : %', v_total_stores;
  RAISE NOTICE '  new grants   : % (0 = already fully provisioned)', v_new_grants;
  RAISE NOTICE '------------------------------------------------------------';

END $$;
