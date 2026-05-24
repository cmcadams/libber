-- ── Soft delete for stores + customer membership removal ──────────────────────
-- Part 1: stores.is_active / deleted_at columns + admin archive/restore RPCs
-- Part 2: manager_remove_customer_from_store RPC
-- Part 3: store_memberships.is_active column
-- Touches: load_customer_home, load_store_members, admin_load_store_members,
--          approve_staff_applicant, join_store
-- Idempotent: safe to re-run.

-- ── 1. Schema ─────────────────────────────────────────────────────────────────

ALTER TABLE public.stores
  ADD COLUMN IF NOT EXISTS is_active  boolean     NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz;

ALTER TABLE public.store_memberships
  ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true;

-- ── 2. admin_archive_store ────────────────────────────────────────────────────
-- Sets is_active=false and records deletion time. Does not delete any data.

CREATE OR REPLACE FUNCTION public.admin_archive_store(p_store_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_store_id IS NULL THEN RAISE EXCEPTION 'missing store_id'; END IF;
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  UPDATE public.stores
  SET    is_active  = false,
         deleted_at = now()
  WHERE  id = p_store_id;

  IF NOT FOUND THEN RAISE EXCEPTION 'store not found'; END IF;

  RETURN json_build_object('success', true, 'store_id', p_store_id);
END $$;

GRANT EXECUTE ON FUNCTION public.admin_archive_store(uuid) TO authenticated;

-- ── 3. admin_restore_store ────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_restore_store(p_store_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_store_id IS NULL THEN RAISE EXCEPTION 'missing store_id'; END IF;
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  UPDATE public.stores
  SET    is_active  = true,
         deleted_at = NULL
  WHERE  id = p_store_id;

  IF NOT FOUND THEN RAISE EXCEPTION 'store not found'; END IF;

  RETURN json_build_object('success', true, 'store_id', p_store_id);
END $$;

GRANT EXECUTE ON FUNCTION public.admin_restore_store(uuid) TO authenticated;

-- ── 4. manager_remove_customer_from_store ────────────────────────────────────
-- Soft-removes a customer from a store by setting their membership is_active=false.
-- Preserves all points_ledger history. Does not touch staff/manager tables.

CREATE OR REPLACE FUNCTION public.manager_remove_customer_from_store(
  p_user_id  uuid,
  p_store_id uuid
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_user_id  IS NULL THEN RAISE EXCEPTION 'missing user_id'; END IF;
  IF p_store_id IS NULL THEN RAISE EXCEPTION 'missing store_id'; END IF;

  PERFORM public.assert_store_manager(p_store_id);

  IF NOT EXISTS (
    SELECT 1 FROM public.store_memberships
    WHERE  user_id   = p_user_id
      AND  store_id  = p_store_id
      AND  is_active = true
  ) THEN
    RAISE EXCEPTION 'user is not an active member of this store';
  END IF;

  UPDATE public.store_memberships
  SET    is_active = false
  WHERE  user_id  = p_user_id
    AND  store_id = p_store_id;

  RETURN json_build_object('success', true, 'user_id', p_user_id, 'store_id', p_store_id);
END $$;

GRANT EXECUTE ON FUNCTION public.manager_remove_customer_from_store(uuid, uuid) TO authenticated;

-- ── 5. join_store — reactivate if previously removed ─────────────────────────
-- ON CONFLICT now sets is_active=true so a removed customer can rejoin cleanly.

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

  IF v_user_id IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_store_id IS NULL THEN RAISE EXCEPTION 'missing store_id'; END IF;

  INSERT INTO public.store_memberships (user_id, store_id)
  VALUES (v_user_id, p_store_id)
  ON CONFLICT (user_id, store_id) DO UPDATE SET is_active = true;

  RETURN json_build_object('success', true, 'user_id', v_user_id, 'store_id', p_store_id);
END $$;

-- ── 6. approve_staff_applicant — membership must be active ───────────────────

CREATE OR REPLACE FUNCTION public.approve_staff_applicant(p_user_id uuid, p_store_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_user_id  IS NULL THEN RAISE EXCEPTION 'missing user_id'; END IF;
  IF p_store_id IS NULL THEN RAISE EXCEPTION 'missing store_id'; END IF;

  PERFORM public.assert_store_manager(p_store_id);

  IF NOT EXISTS (
    SELECT 1 FROM public.store_memberships
    WHERE  user_id   = p_user_id
      AND  store_id  = p_store_id
      AND  is_active = true
  ) THEN
    RAISE EXCEPTION 'user is not an active member of this store';
  END IF;

  INSERT INTO public.store_staff (user_id, store_id)
  VALUES (p_user_id, p_store_id)
  ON CONFLICT DO NOTHING;

  RETURN json_build_object('success', true, 'user_id', p_user_id, 'store_id', p_store_id);
END $$;

-- ── 7. load_store_members — only active members ───────────────────────────────

CREATE OR REPLACE FUNCTION public.load_store_members(p_store_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM public.assert_store_access(p_store_id);

  RETURN (
    SELECT json_agg(row_to_json(t))
    FROM (
      SELECT
        sm.user_id,
        p.public_id,
        COALESCE(
          (SELECT running_balance
           FROM public.points_ledger pl
           WHERE pl.user_id = sm.user_id AND pl.store_id = p_store_id
           ORDER BY pl.created_at DESC
           LIMIT 1),
          0
        ) AS balance
      FROM public.store_memberships sm
      LEFT JOIN public.profiles p ON p.user_id = sm.user_id
      WHERE sm.store_id  = p_store_id
        AND sm.is_active = true
      ORDER BY p.public_id
    ) t
  );
END $$;

-- ── 8. admin_load_store_members — only active members ────────────────────────

CREATE OR REPLACE FUNCTION public.admin_load_store_members(p_store_id uuid)
RETURNS TABLE(user_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM public.assert_store_manager(p_store_id);

  RETURN QUERY
    SELECT sm.user_id
    FROM   public.store_memberships sm
    WHERE  sm.store_id  = p_store_id
      AND  sm.is_active = true;
END $$;

-- ── 9. load_customer_home — hide archived stores and inactive memberships ─────
-- Adds two filters:
--   AND sm.is_active = true  (hide removed memberships)
--   AND s.is_active  = true  (hide archived stores in membership list)
--   WHERE is_active  = true  (hide archived stores in the browse list)

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
        WHERE sm.user_id   = v_user_id
          AND sm.is_active = true
          AND s.is_active  = true
        ORDER BY s.name
      ) sub
    ),
    'stores', CASE WHEN p_include_stores THEN (
      SELECT COALESCE(
        json_agg(json_build_object('id', id, 'name', name) ORDER BY name),
        '[]'::json
      )
      FROM public.stores
      WHERE is_active = true
    ) ELSE NULL END
  );
END $$;
