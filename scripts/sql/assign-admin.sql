-- Assign yourself as admin using your human-readable public_id.
-- Your public_id is shown in the admin tool user list.
-- Run in the Supabase SQL Editor (Dashboard → SQL Editor).

DO $$
DECLARE
  v_user_id uuid;
BEGIN
  SELECT user_id INTO v_user_id FROM public.profiles WHERE public_id = 'MQH 335 484';
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'public_id not found'; END IF;
  INSERT INTO public.admins (user_id) VALUES (v_user_id) ON CONFLICT DO NOTHING;
  RAISE NOTICE 'Admin assigned: %', v_user_id;
END $$;
