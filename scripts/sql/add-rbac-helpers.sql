-- add-rbac-helpers.sql
--
-- Centralises store-level permission checks into a single source of truth.
-- Replaces the inline UNION queries duplicated across multiple RPCs.
--
-- Three new functions:
--   public.get_store_role(p_store_id)    → 'admin' | 'manager' | 'staff' | null
--   public.assert_store_access(p_store_id) → raises if caller has no role
--   public.assert_store_manager(p_store_id) → raises if caller is not manager/admin
--
-- Then rewrites all 7 affected RPCs to use the wrappers.
--
-- Safe to re-run — CREATE OR REPLACE everywhere.
-- Run in Supabase SQL Editor (Dashboard → SQL Editor).
-- Re-run fix-default-privileges.sql afterwards.

-- ── Indexes (idempotent) ──────────────────────────────────────────────────────
-- get_store_role does three point lookups; covering indexes keep them O(1).

CREATE INDEX IF NOT EXISTS admins_user_id_idx
  ON public.admins (user_id);

CREATE INDEX IF NOT EXISTS store_managers_user_store_idx
  ON public.store_managers (user_id, store_id);

CREATE INDEX IF NOT EXISTS store_staff_user_store_idx
  ON public.store_staff (user_id, store_id);

-- ── get_store_role ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.get_store_role(p_store_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
STABLE
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RETURN null; END IF;
  IF EXISTS (SELECT 1 FROM public.admins         WHERE user_id = v_uid)                                   THEN RETURN 'admin';   END IF;
  IF EXISTS (SELECT 1 FROM public.store_managers WHERE user_id = v_uid AND store_id = p_store_id)         THEN RETURN 'manager'; END IF;
  IF EXISTS (SELECT 1 FROM public.store_staff    WHERE user_id = v_uid AND store_id = p_store_id)         THEN RETURN 'staff';   END IF;
  RETURN null;
END $$;

-- ── assert_store_access ───────────────────────────────────────────────────────
-- Passes for: admin, manager, staff. Raises for unauthenticated or no role.

CREATE OR REPLACE FUNCTION public.assert_store_access(p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF public.get_store_role(p_store_id) IS NULL THEN
    RAISE EXCEPTION 'not authorized: staff or manager access required for this store';
  END IF;
END $$;

-- ── assert_store_manager ──────────────────────────────────────────────────────
-- Passes for: admin, manager. Raises for staff, unauthenticated, or no role.

CREATE OR REPLACE FUNCTION public.assert_store_manager(p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF public.get_store_role(p_store_id) NOT IN ('manager', 'admin') THEN
    RAISE EXCEPTION 'not authorized: manager or admin access required for this store';
  END IF;
END $$;

-- ── award_points ──────────────────────────────────────────────────────────────
-- Replaces the inline store_staff UNION store_managers check.
-- Signature unchanged (add-outlets.sql already has the 6-arg version).

CREATE OR REPLACE FUNCTION public.award_points(
  p_user_id   uuid,
  p_store_id  uuid,
  p_points    integer,
  p_reason    text,
  p_rule_id   uuid DEFAULT NULL,
  p_outlet_id uuid DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_staff_id        uuid := auth.uid();
  v_max_bonus       integer;
  v_current_balance integer;
  v_new_balance     integer;
BEGIN
  IF v_staff_id IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;

  PERFORM public.assert_store_access(p_store_id);

  -- Serialize concurrent calls for the same (user, store) pair.
  PERFORM pg_advisory_xact_lock(hashtext(p_user_id::text), hashtext(p_store_id::text));

  IF p_points = 0 THEN RAISE EXCEPTION 'points cannot be zero'; END IF;

  IF p_points > 0 THEN
    IF p_rule_id IS NOT NULL THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.store_reward_rules
        WHERE id       = p_rule_id
          AND store_id = p_store_id
          AND is_active = true
          AND kind     = 'award'
          AND points   = p_points
      ) THEN
        RAISE EXCEPTION 'invalid rule for this award';
      END IF;
    ELSE
      SELECT max_bonus_points INTO v_max_bonus FROM public.stores WHERE id = p_store_id;
      IF v_max_bonus IS NOT NULL AND p_points > v_max_bonus THEN
        RAISE EXCEPTION 'exceeds bonus cap of % points for this store', v_max_bonus;
      END IF;
    END IF;
  ELSE
    -- Negative points = redemption; must reference a configured rule.
    IF p_rule_id IS NULL THEN
      RAISE EXCEPTION 'redemptions must reference a reward rule (p_rule_id required)';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.store_reward_rules
      WHERE id       = p_rule_id
        AND store_id = p_store_id
        AND is_active = true
        AND kind     = 'redeem'
        AND points   = -p_points
    ) THEN
      RAISE EXCEPTION 'invalid rule for this redemption';
    END IF;
  END IF;

  -- Validate outlet belongs to this store if provided
  IF p_outlet_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.store_outlets
      WHERE id = p_outlet_id AND store_id = p_store_id
    ) THEN
      RAISE EXCEPTION 'outlet does not belong to this store';
    END IF;
  END IF;

  SELECT running_balance INTO v_current_balance
  FROM public.points_ledger
  WHERE user_id = p_user_id AND store_id = p_store_id
  ORDER BY created_at DESC
  LIMIT 1;

  v_current_balance := coalesce(v_current_balance, 0);
  v_new_balance     := v_current_balance + p_points;

  IF v_new_balance < 0 THEN
    RAISE EXCEPTION 'insufficient points: balance is % but operation requires %',
      v_current_balance, -p_points;
  END IF;

  INSERT INTO public.points_ledger
    (user_id, store_id, points, reason, created_by, running_balance, outlet_id)
  VALUES
    (p_user_id, p_store_id, p_points, p_reason, v_staff_id, v_new_balance, p_outlet_id);

  RETURN v_new_balance;
END $$;

-- ── adjust_points ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.adjust_points(
  p_user_id   uuid,
  p_store_id  uuid,
  p_points    integer,
  p_reason    text,
  p_outlet_id uuid DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_staff_id        uuid := auth.uid();
  v_current_balance integer;
  v_new_balance     integer;
BEGIN
  IF v_staff_id IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_points = 0       THEN RAISE EXCEPTION 'points cannot be zero'; END IF;

  PERFORM public.assert_store_access(p_store_id);

  IF p_outlet_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.store_outlets
      WHERE id = p_outlet_id AND store_id = p_store_id
    ) THEN
      RAISE EXCEPTION 'outlet does not belong to this store';
    END IF;
  END IF;

  SELECT running_balance INTO v_current_balance
  FROM public.points_ledger
  WHERE user_id = p_user_id AND store_id = p_store_id
  ORDER BY created_at DESC
  LIMIT 1;

  v_current_balance := coalesce(v_current_balance, 0);
  v_new_balance     := v_current_balance + p_points;

  INSERT INTO public.points_ledger
    (user_id, store_id, points, reason, created_by, running_balance, outlet_id)
  VALUES
    (p_user_id, p_store_id, p_points, p_reason, v_staff_id, v_new_balance, p_outlet_id);

  RETURN v_new_balance;
END $$;

-- ── load_store_members ────────────────────────────────────────────────────────

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
      WHERE sm.store_id = p_store_id
      ORDER BY p.public_id
    ) t
  );
END $$;

-- ── load_store_outlets ────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.load_store_outlets(p_store_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM public.assert_store_access(p_store_id);

  RETURN (
    SELECT COALESCE(json_agg(
      json_build_object('id', id, 'name', name)
      ORDER BY name
    ), '[]'::json)
    FROM public.store_outlets
    WHERE store_id = p_store_id
  );
END $$;

-- ── load_store_staff_profiles ─────────────────────────────────────────────────
-- Manager-only: uses assert_store_manager.

CREATE OR REPLACE FUNCTION public.load_store_staff_profiles(p_store_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM public.assert_store_manager(p_store_id);

  RETURN (
    SELECT COALESCE(json_agg(json_build_object(
      'user_id',    ss.user_id,
      'public_id',  p.public_id,
      'created_at', ss.created_at
    ) ORDER BY ss.created_at), '[]'::json)
    FROM public.store_staff ss
    LEFT JOIN public.profiles p ON p.user_id = ss.user_id
    WHERE ss.store_id = p_store_id
  );
END $$;

-- ── approve_staff_applicant ───────────────────────────────────────────────────
-- Requires manager or admin. Preserves the store-membership guard.

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
    WHERE user_id = p_user_id AND store_id = p_store_id
  ) THEN
    RAISE EXCEPTION 'user is not a member of this store';
  END IF;

  INSERT INTO public.store_staff (user_id, store_id)
  VALUES (p_user_id, p_store_id)
  ON CONFLICT DO NOTHING;

  RETURN json_build_object('success', true, 'user_id', p_user_id, 'store_id', p_store_id);
END $$;

-- ── demote_store_staff ────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.demote_store_staff(p_user_id uuid, p_store_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_store_id IS NULL THEN RAISE EXCEPTION 'missing store_id'; END IF;
  IF p_user_id  IS NULL THEN RAISE EXCEPTION 'missing user_id'; END IF;

  PERFORM public.assert_store_manager(p_store_id);

  DELETE FROM public.store_staff
  WHERE user_id = p_user_id AND store_id = p_store_id;

  RETURN json_build_object('success', true, 'user_id', p_user_id, 'store_id', p_store_id);
END $$;

-- ── Grants ────────────────────────────────────────────────────────────────────

GRANT EXECUTE ON FUNCTION public.get_store_role(uuid)          TO authenticated;
GRANT EXECUTE ON FUNCTION public.assert_store_access(uuid)     TO authenticated;
GRANT EXECUTE ON FUNCTION public.assert_store_manager(uuid)    TO authenticated;
GRANT EXECUTE ON FUNCTION public.award_points(uuid, uuid, integer, text, uuid, uuid)  TO authenticated;
GRANT EXECUTE ON FUNCTION public.adjust_points(uuid, uuid, integer, text, uuid)       TO authenticated;
GRANT EXECUTE ON FUNCTION public.load_store_members(uuid)             TO authenticated;
GRANT EXECUTE ON FUNCTION public.load_store_outlets(uuid)             TO authenticated;
GRANT EXECUTE ON FUNCTION public.load_store_staff_profiles(uuid)      TO authenticated;
GRANT EXECUTE ON FUNCTION public.approve_staff_applicant(uuid, uuid)  TO authenticated;
GRANT EXECUTE ON FUNCTION public.demote_store_staff(uuid, uuid)       TO authenticated;

-- ── Re-run fix-default-privileges.sql after this script ──────────────────────
