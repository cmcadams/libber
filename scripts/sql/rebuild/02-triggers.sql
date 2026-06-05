-- 02-triggers.sql
--
-- The create_profile trigger: fires on every INSERT into auth.users and creates
-- a profiles row with a unique public_id and an A/B variant assignment.
--
-- Run order: AFTER 01-schema.sql (requires profiles and ab_variants to exist).
-- Trigger functions are SECURITY DEFINER and not called directly by clients —
-- no GRANT EXECUTE needed.
--
-- Audit: no changes required. The trigger selects only the `variant` column
-- from ab_variants (not the renamed display_text column). No other audit
-- finding applies to this file.
--
-- Bugs fixed vs the original migration chain:
--   1. ceil(random() * N) can produce 0 when random() = 0.0 exactly; substring
--      at position 0 returns ''. Fixed: floor(random() * N) + 1 always → 1..N.
--   2. No retry loop for public_id uniqueness collisions. A collision caused a
--      constraint violation that the trigger swallowed, leaving the user with no
--      profile row. Fixed: LOOP … EXIT WHEN NOT EXISTS.
--   3. No EXCEPTION handler. Trigger failures were invisible and silently
--      prevented downstream operations. Fixed: EXCEPTION WHEN OTHERS logs a
--      WARNING and returns NEW so auth.users INSERT is never blocked.

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
  -- Assign A/B variant via weighted reservoir sampling (Efraimidis-Spirakis).
  -- Selects only the variant key ('A', 'B', …); display text is looked up at
  -- query time by load_customer_home. Gracefully handles zero variants
  -- (v_variant stays NULL, profile is created without a variant assignment).
  SELECT variant INTO v_variant
  FROM   public.ab_variants
  WHERE  test_name = 'save_prompt'
  AND    is_active = true
  AND    weight    > 0
  ORDER BY pow(random(), 1.0 / weight) DESC
  LIMIT  1;

  -- Generate a collision-safe unique public_id.
  -- Format: "ABC 123 456"  (3 letters, space, 3 digits, space, 3 digits)
  -- Letters exclude I and O to avoid visual ambiguity with 1 and 0.
  -- floor(random() * N) + 1 guarantees positions 1..N; ceil can yield 0.
  LOOP
    v_pid :=
      (SELECT string_agg(
         substring('ABCDEFGHJKLMNPQRSTUVWXYZ', (floor(random() * 24) + 1)::int, 1), ''
       ) FROM generate_series(1, 3))
      || ' ' ||
      (SELECT string_agg(
         substring('0123456789', (floor(random() * 10) + 1)::int, 1), ''
       ) FROM generate_series(1, 3))
      || ' ' ||
      (SELECT string_agg(
         substring('0123456789', (floor(random() * 10) + 1)::int, 1), ''
       ) FROM generate_series(1, 3));

    EXIT WHEN NOT EXISTS (SELECT 1 FROM public.profiles WHERE public_id = v_pid);
  END LOOP;

  INSERT INTO public.profiles (user_id, public_id, save_prompt_variant)
  VALUES (NEW.id, v_pid, v_variant);

  RETURN NEW;

EXCEPTION WHEN OTHERS THEN
  -- Log so the failure appears in Supabase Postgres logs; do NOT block user
  -- creation. Run the backfill script (if needed) to recover missing profiles.
  RAISE WARNING 'create_profile failed for user %: % (SQLSTATE %)',
    NEW.id, SQLERRM, SQLSTATE;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.create_profile();
