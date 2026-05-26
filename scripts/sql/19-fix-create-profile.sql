-- 19-fix-create-profile.sql
--
-- Fixes the create_profile() trigger function.
--
-- Two bugs in the version from 07-schema-ab-testing.sql:
--
--   1. ceil(random() * N) can return 0 when random() returns exactly 0.0.
--      PostgreSQL's random() returns [0, 1), so 0.0 is possible.
--      ceil(0.0) = 0, and substring(str, 0, 1) returns '' (empty string),
--      producing a malformed public_id such as ' 123 456' (leading space).
--      Fix: use floor(random() * N) + 1, which always yields 1..N.
--
--   2. No retry loop for uniqueness collisions. Extremely rare but possible;
--      a collision causes a unique constraint violation and the function
--      fails, leaving the new user with no profile. Supabase's auth system
--      swallows the trigger exception so user creation succeeds but no
--      profile is ever created.
--      Fix: retry loop identical to the backfill in 18-backfill-profiles.sql.
--
--   3. No EXCEPTION handler. A silent failure in the trigger is invisible —
--      there is no log entry, no error returned to the client.
--      Fix: EXCEPTION WHEN OTHERS block logs a WARNING (visible in Supabase
--      Postgres logs) and returns NEW so user creation is never blocked.
--      The backfill migration (18) recovers any user who slipped through.
--
-- Depends on:
--   00-base-schema.sql (profiles table)
--   07-schema-ab-testing.sql (ab_variants table, trigger)
--
-- Safe to re-run: yes (CREATE OR REPLACE).
-- Does NOT need 15-final-grants.sql re-run (trigger functions are not called
-- directly by clients — they run via the trigger as the function owner).

CREATE OR REPLACE FUNCTION public.create_profile()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_variant text;
  v_pid     text;
BEGIN
  -- A/B variant: weighted reservoir sampling (unchanged from migration 07).
  SELECT variant INTO v_variant
  FROM   public.ab_variants
  WHERE  test_name = 'save_prompt'
  AND    is_active = true
  AND    weight    > 0
  ORDER BY pow(random(), 1.0 / weight) DESC
  LIMIT  1;

  -- Generate a unique public_id, retrying on collision.
  -- Uses floor(random() * N) + 1 to guarantee positions 1..N (ceil could give 0).
  LOOP
    v_pid :=
      -- 3 letters from 24-char alphabet (no I or O — visually ambiguous)
      (SELECT string_agg(
         substring('ABCDEFGHJKLMNPQRSTUVWXYZ', (floor(random() * 24) + 1)::int, 1),
         ''
       )
       FROM generate_series(1, 3))
      || ' ' ||
      -- 3 digits
      (SELECT string_agg(
         substring('0123456789', (floor(random() * 10) + 1)::int, 1),
         ''
       )
       FROM generate_series(1, 3))
      || ' ' ||
      -- 3 more digits
      (SELECT string_agg(
         substring('0123456789', (floor(random() * 10) + 1)::int, 1),
         ''
       )
       FROM generate_series(1, 3));

    EXIT WHEN NOT EXISTS (SELECT 1 FROM public.profiles WHERE public_id = v_pid);
  END LOOP;

  INSERT INTO public.profiles (user_id, public_id, save_prompt_variant)
  VALUES (NEW.id, v_pid, v_variant);

  RETURN NEW;

EXCEPTION WHEN OTHERS THEN
  -- Log the failure so it appears in Supabase Postgres logs.
  -- RETURN NEW so user creation in auth.users is never blocked by a profile error.
  -- Run 18-backfill-profiles.sql to recover any user left without a profile.
  RAISE WARNING 'create_profile failed for user %: % (SQLSTATE %)',
    NEW.id, SQLERRM, SQLSTATE;
  RETURN NEW;
END;
$$;
