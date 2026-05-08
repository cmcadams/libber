-- add-store-logo.sql
-- Adds logo_path + logo_updated_at to stores, creates the admin RPC to set it,
-- updates load_customer_home to return logo fields, and defines storage policies.
--
-- Run in: Supabase Dashboard → SQL Editor.
-- The storage bucket must be created first (see step 0 below).

-- ── 0. Storage bucket ─────────────────────────────────────────────────────────
-- Create via Dashboard: Storage → New bucket → name: store-logos, Public: on
-- OR run:

INSERT INTO storage.buckets (id, name, public)
VALUES ('store-logos', 'store-logos', true)
ON CONFLICT (id) DO NOTHING;

-- ── 1. Storage policies ───────────────────────────────────────────────────────
-- Path convention: stores/{store_id}/logo.webp
-- Policy extracts store_id from path position [2] and compares as text to avoid
-- cast failures on malformed paths (which would otherwise throw, not deny).

DROP POLICY IF EXISTS "store logos are publicly readable"    ON storage.objects;
DROP POLICY IF EXISTS "managers and admins can upload logos" ON storage.objects;
DROP POLICY IF EXISTS "managers and admins can update logos" ON storage.objects;
DROP POLICY IF EXISTS "admins can upload logos"              ON storage.objects;
DROP POLICY IF EXISTS "admins can update logos"              ON storage.objects;

CREATE POLICY "store logos are publicly readable"
ON storage.objects FOR SELECT
USING (bucket_id = 'store-logos');

CREATE POLICY "admins can upload logos"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'store-logos' AND public.is_admin()
);

CREATE POLICY "admins can update logos"
ON storage.objects FOR UPDATE
TO authenticated
USING (
  bucket_id = 'store-logos' AND public.is_admin()
);

-- ── 2. Schema ─────────────────────────────────────────────────────────────────

ALTER TABLE public.stores
  ADD COLUMN IF NOT EXISTS logo_path       text,
  ADD COLUMN IF NOT EXISTS logo_updated_at timestamptz;

-- ── 3. RPC: admin_set_store_logo ──────────────────────────────────────────────
-- Caller must be a global admin. Managers cannot change logos.
-- Updates both logo_path and logo_updated_at atomically.

CREATE OR REPLACE FUNCTION public.admin_set_store_logo(
  p_store_id  uuid,
  p_logo_path text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Not authorized — only admins can change store logos';
  END IF;

  IF p_logo_path IS DISTINCT FROM ('stores/' || p_store_id::text || '/logo.webp') THEN
    RAISE EXCEPTION 'Invalid logo_path — must be stores/<store_id>/logo.webp';
  END IF;

  UPDATE public.stores
  SET    logo_path       = p_logo_path,
         logo_updated_at = now()
  WHERE  id = p_store_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Store not found: %', p_store_id;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_set_store_logo(uuid, text) TO authenticated;

-- ── 4. Update load_customer_home ──────────────────────────────────────────────
-- Adds logo_path + logo_updated_at to each membership object.
-- Adds logo_path to the available stores list.
-- All other logic is unchanged from the ab-testing version.

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
          'store_id',        sm.store_id,
          'store_name',      s.name,
          'logo_path',       s.logo_path,
          'logo_updated_at', s.logo_updated_at,
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
        json_agg(json_build_object(
          'id',        id,
          'name',      name,
          'logo_path', logo_path
        ) ORDER BY name),
        '[]'::json
      )
      FROM public.stores
    ) ELSE NULL END
  );
END $$;
