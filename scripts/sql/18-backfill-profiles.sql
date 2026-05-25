-- 18-backfill-profiles.sql
--
-- Backfills a profiles row for any auth.users entry that lacks one.
--
-- Root cause this fixes:
--   The on_auth_user_created trigger (07-schema-ab-testing.sql) fires on every
--   INSERT into auth.users. If a user was created before the trigger existed,
--   or if the trigger failed silently (e.g. a transient error during anonymous
--   auth initialisation), that user ends up with no profile row. This migration
--   closes the gap for all such users.
--
-- Uses identical logic to create_profile():
--   - public_id: 3 uppercase letters (ABCDEFGHJKLMNPQRSTUVWXYZ, no I/O) +
--                space + 3 digits + space + 3 digits
--   - save_prompt_variant: weighted reservoir sampling from ab_variants
--   - Collision retry loop: generates a new public_id if the generated one
--     already exists (extremely rare, handles it correctly).
--
-- Depends on:
--   00-base-schema.sql (profiles table)
--   07-schema-ab-testing.sql (ab_variants table, create_profile function)
--
-- Safe to re-run: yes — the FOR loop only processes users without a profile.
-- Does NOT need 15-final-grants.sql re-run (no new functions).

DO $$
DECLARE
  u          RECORD;
  v_pid      text;
  v_variant  text;
  v_count    integer := 0;
BEGIN
  FOR u IN
    SELECT au.id
    FROM   auth.users au
    WHERE  NOT EXISTS (
      SELECT 1 FROM public.profiles p WHERE p.user_id = au.id
    )
  LOOP
    -- Generate a unique public_id, retrying on collision (extremely rare).
    LOOP
      v_pid :=
        -- 3 letters from alphabet without I and O (avoids visual ambiguity)
        (SELECT string_agg(char, '')
         FROM (
           SELECT substring('ABCDEFGHJKLMNPQRSTUVWXYZ', ceil(random() * 24)::int, 1) AS char
           FROM generate_series(1, 3)
         ) t)
        || ' ' ||
        -- 3 digits
        (SELECT string_agg(char, '')
         FROM (
           SELECT substring('0123456789', ceil(random() * 10)::int, 1) AS char
           FROM generate_series(1, 3)
         ) t)
        || ' ' ||
        -- 3 more digits
        (SELECT string_agg(char, '')
         FROM (
           SELECT substring('0123456789', ceil(random() * 10)::int, 1) AS char
           FROM generate_series(1, 3)
         ) t);

      EXIT WHEN NOT EXISTS (SELECT 1 FROM public.profiles WHERE public_id = v_pid);
    END LOOP;

    -- Assign A/B variant using same weighted reservoir sampling as the trigger.
    SELECT variant INTO v_variant
    FROM   public.ab_variants
    WHERE  test_name = 'save_prompt'
    AND    is_active  = true
    AND    weight     > 0
    ORDER BY pow(random(), 1.0 / weight) DESC
    LIMIT  1;

    INSERT INTO public.profiles (user_id, public_id, save_prompt_variant)
    VALUES (u.id, v_pid, v_variant);

    v_count := v_count + 1;
    RAISE NOTICE 'Created profile for user % → public_id %', u.id, v_pid;
  END LOOP;

  RAISE NOTICE 'Backfill complete: % profile(s) created.', v_count;
END $$;
