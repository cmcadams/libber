-- A/B testing framework for save prompt and future experiments.
-- Safe to re-run (idempotent). Run in Supabase SQL Editor.

-- ── ab_variants table ─────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.ab_variants (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  test_name  text        NOT NULL,
  variant    text        NOT NULL,
  text       text        NOT NULL,
  position   text        NOT NULL DEFAULT 'middle',
  is_active  boolean     NOT NULL DEFAULT true,
  weight     int         NOT NULL DEFAULT 50 CHECK (weight >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (test_name, variant)
);

ALTER TABLE public.ab_variants ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "ab_variants: allow select"    ON public.ab_variants;
DROP POLICY IF EXISTS "ab_variants: no direct write"  ON public.ab_variants; -- replaced below
DROP POLICY IF EXISTS "ab_variants: no direct insert" ON public.ab_variants;
DROP POLICY IF EXISTS "ab_variants: no direct update" ON public.ab_variants;
DROP POLICY IF EXISTS "ab_variants: no direct delete" ON public.ab_variants;

-- SELECT: variant data is non-sensitive; readable by all authenticated users.
CREATE POLICY "ab_variants: allow select" ON public.ab_variants
  FOR SELECT USING (true);

-- Writes: blocked on the client. Variants are managed via the Supabase dashboard.
-- Three separate RESTRICTIVE policies — one per write operation — so SELECT is unaffected.
CREATE POLICY "ab_variants: no direct insert" ON public.ab_variants
  AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY "ab_variants: no direct update" ON public.ab_variants
  AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY "ab_variants: no direct delete" ON public.ab_variants
  AS RESTRICTIVE FOR DELETE USING (false);

-- ── Initial save_prompt variants ──────────────────────────────────────────────

INSERT INTO public.ab_variants (test_name, variant, text, position, weight)
VALUES
  ('save_prompt', 'A', 'Save your points',        'middle', 50),
  ('save_prompt', 'B', 'Don''t lose your points', 'middle', 50)
ON CONFLICT (test_name, variant) DO NOTHING;

-- ── Add tracking columns to profiles ─────────────────────────────────────────

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS save_prompt_variant      text,
  ADD COLUMN IF NOT EXISTS interaction_count        int         NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS one_time_prompt_shown_at timestamptz,
  ADD COLUMN IF NOT EXISTS prompt_dismissed_at      timestamptz,
  ADD COLUMN IF NOT EXISTS account_linked_at         timestamptz;

-- ── Update create_profile trigger ─────────────────────────────────────────────
-- Variant assignment uses pow(random(), 1.0/weight) — Efraimidis-Spirakis
-- weighted reservoir sampling — which gives exactly proportional probability.
-- e.g. weights [80, 20] → 80% chance of A, 20% chance of B.

CREATE OR REPLACE FUNCTION public.create_profile()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_variant text;
BEGIN
  SELECT variant INTO v_variant
  FROM   public.ab_variants
  WHERE  test_name = 'save_prompt'
  AND    is_active = true
  AND    weight    > 0
  ORDER BY pow(random(), 1.0 / weight) DESC
  LIMIT  1;

  INSERT INTO public.profiles (user_id, public_id, save_prompt_variant)
  VALUES (
    NEW.id,
    (
      SELECT string_agg(char, '')
      FROM (
        SELECT substring('ABCDEFGHJKLMNPQRSTUVWXYZ', ceil(random() * 24)::int, 1) AS char
        FROM generate_series(1, 3)
      ) t
    ) || ' ' ||
    (
      SELECT string_agg(char, '')
      FROM (
        SELECT substring('0123456789', ceil(random() * 10)::int, 1) AS char
        FROM generate_series(1, 3)
      ) t
    ) || ' ' ||
    (
      SELECT string_agg(char, '')
      FROM (
        SELECT substring('0123456789', ceil(random() * 10)::int, 1) AS char
        FROM generate_series(1, 3)
      ) t
    ),
    v_variant
  );
  RETURN NEW;
END;
$$;

-- ── Update load_customer_home ─────────────────────────────────────────────────
-- Single profiles SELECT (was three separate subqueries).
-- Always returns the save_prompt key — null when no variant is assigned —
-- so the client can distinguish a fresh RPC response from an old cached response
-- that predates this feature (which will not have the key at all).

CREATE OR REPLACE FUNCTION public.load_customer_home(p_include_stores boolean DEFAULT true)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id        uuid;
  v_public_id      text;
  v_variant        text;
  v_account_linked boolean;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;

  SELECT public_id,
         save_prompt_variant,
         (account_linked_at IS NOT NULL)
  INTO   v_public_id, v_variant, v_account_linked
  FROM   public.profiles
  WHERE  user_id = v_user_id;

  RETURN json_build_object(
    'public_id',      v_public_id,
    'account_linked', COALESCE(v_account_linked, false),
    'save_prompt', (
      SELECT json_build_object(
        'variant',  v.variant,
        'text',     v.text,
        'position', v.position
      )
      FROM   public.ab_variants v
      WHERE  v.test_name = 'save_prompt'
      AND    v.variant   = v_variant
      AND    v.is_active = true
      LIMIT  1
    ),
    'memberships', (
      SELECT COALESCE(json_agg(m_data), '[]'::json)
      FROM (
        SELECT json_build_object(
          'store_id',   sm.store_id,
          'store_name', s.name,
          'balance', COALESCE((
            SELECT running_balance FROM public.points_ledger
            WHERE user_id = v_user_id AND store_id = sm.store_id
            ORDER BY created_at DESC LIMIT 1
          ), 0),
          'rules', (
            SELECT COALESCE(json_agg(json_build_object(
              'label',  rr.label,
              'points', rr.points,
              'kind',   rr.kind
            ) ORDER BY rr.sort_order), '[]'::json)
            FROM public.store_reward_rules rr
            WHERE rr.store_id = sm.store_id AND rr.is_active = true
          ),
          'history', (
            SELECT COALESCE(json_agg(json_build_object(
              'reason',     h.reason,
              'points',     h.points,
              'created_at', h.created_at
            ) ORDER BY h.created_at DESC), '[]'::json)
            FROM (
              SELECT reason, points, created_at
              FROM public.points_ledger
              WHERE user_id = v_user_id AND store_id = sm.store_id
              ORDER BY created_at DESC
              LIMIT 10
            ) h
          )
        ) AS m_data
        FROM public.store_memberships sm
        JOIN public.stores s ON s.id = sm.store_id
        WHERE sm.user_id = v_user_id
        ORDER BY s.name
      ) sub
    ),
    'stores', CASE WHEN p_include_stores THEN (
      SELECT COALESCE(
        json_agg(json_build_object('id', id, 'name', name) ORDER BY name),
        '[]'::json
      )
      FROM public.stores
    ) ELSE NULL END
  );
END $$;

-- ── Backfill existing profiles ────────────────────────────────────────────────
-- Assigns a weighted-random variant to profiles created before this feature.
-- Safe to re-run — WHERE clause means subsequent runs update zero rows.

UPDATE public.profiles
SET    save_prompt_variant = (
  SELECT variant
  FROM   public.ab_variants
  WHERE  test_name = 'save_prompt'
  AND    is_active = true
  AND    weight    > 0
  ORDER BY pow(random(), 1.0 / weight) DESC
  LIMIT  1
)
WHERE save_prompt_variant IS NULL;

-- ── Create profile trigger ────────────────────────────────────────────────────
-- The create_profile() function is defined above but the trigger was never
-- created by the original script. Added here so the rebuild creates it correctly.

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.create_profile();
