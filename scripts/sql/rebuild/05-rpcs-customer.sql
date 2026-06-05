-- 05-rpcs-customer.sql
--
-- Customer-facing RPCs. All are scoped to auth.uid() — no impersonation path.
-- No RBAC check: any authenticated user can call these for their own data.
--
-- Run order: AFTER 03-auth-helpers.sql (assert_store_active, assert_active_membership).
--
-- Audit fixes applied:
--   MINOR  load_customer_home: v.text → v.display_text following the column
--          rename in 01-schema.sql; the JSON key returned to the client
--          remains 'text' (aliased in json_build_object) so the client
--          contract is unchanged
--   MINOR  load_customer_home: added N+1 note explaining the correlated
--          subquery pattern and when it warrants revisiting

-- ── load_customer_home ────────────────────────────────────────────────────────
-- Single bootstrap query for the customer app. Returns profile, A/B variant,
-- active memberships (with balance, rules, last 10 history entries), and
-- optionally the full active store catalogue.
-- Archived stores and inactive memberships are excluded.
--
-- N+1 note: each membership row drives three correlated subqueries (balance,
-- rules aggregation, history aggregation). At typical scale (1–5 stores per
-- customer) this is acceptable. Revisit with a lateral join if membership
-- counts per user grow significantly.

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
        'text',     v.display_text,
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
              FROM   public.points_ledger
              WHERE  user_id  = v_user_id
                AND  store_id = sm.store_id
              ORDER  BY created_at DESC
              LIMIT  10
            ) h
          )
        ) AS m_data
        FROM public.store_memberships sm
        JOIN public.stores s ON s.id = sm.store_id
        WHERE sm.user_id   = v_user_id
          AND sm.is_active = true
          AND s.is_active  = true
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
      WHERE is_active = true
    ) ELSE NULL END
  );
END $$;

-- ── load_points_history ───────────────────────────────────────────────────────
-- Returns the caller's last 10 ledger entries for one store.
-- Returns only: points, reason, created_at — never exposes created_by,
-- running_balance, outlet_id, or any other internal metadata.

CREATE OR REPLACE FUNCTION public.load_points_history(p_store_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id  IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_store_id IS NULL THEN RAISE EXCEPTION 'missing store_id';  END IF;

  RETURN (
    SELECT COALESCE(json_agg(json_build_object(
      'points',     points,
      'reason',     reason,
      'created_at', created_at
    ) ORDER BY created_at DESC), '[]'::json)
    FROM (
      SELECT points, reason, created_at
      FROM   public.points_ledger
      WHERE  user_id  = v_user_id
        AND  store_id = p_store_id
      ORDER  BY created_at DESC
      LIMIT  10
    ) h
  );
END $$;

-- ── join_store ────────────────────────────────────────────────────────────────
-- Creates a membership or reactivates an inactive one.
-- Archived stores are rejected. Idempotent: re-joining an active store is a no-op.

CREATE OR REPLACE FUNCTION public.join_store(p_store_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id  IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_store_id IS NULL THEN RAISE EXCEPTION 'missing store_id';  END IF;

  PERFORM public.assert_store_active(p_store_id);

  INSERT INTO public.store_memberships (user_id, store_id)
  VALUES (v_user_id, p_store_id)
  ON CONFLICT (user_id, store_id) DO UPDATE SET is_active = true;

  RETURN json_build_object('success', true, 'user_id', v_user_id, 'store_id', p_store_id);
END $$;

-- ── unjoin_store ──────────────────────────────────────────────────────────────
-- Soft-removes the caller's membership (is_active = false).
-- Customers can leave archived stores — they can't see them anyway, but allowing
-- it is harmless and keeps the operation always-succeeding.
-- Points history and running_balance are fully preserved.

CREATE OR REPLACE FUNCTION public.unjoin_store(p_store_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id  IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_store_id IS NULL THEN RAISE EXCEPTION 'missing store_id';  END IF;

  UPDATE public.store_memberships
  SET    is_active = false
  WHERE  user_id  = v_user_id
    AND  store_id = p_store_id;

  RETURN json_build_object('success', true, 'user_id', v_user_id, 'store_id', p_store_id);
END $$;

-- ── mark_account_linked ───────────────────────────────────────────────────────
-- Records that the caller has linked their anonymous session to a persistent
-- account (Google OAuth or magic link). Idempotent: only updates if not already set.
-- Called by the save.html page after OAuth or magic-link callback completes.

CREATE OR REPLACE FUNCTION public.mark_account_linked()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;

  UPDATE public.profiles
  SET    account_linked_at = now()
  WHERE  user_id           = v_user_id
    AND  account_linked_at IS NULL;
END $$;
