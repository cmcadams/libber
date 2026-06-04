-- 06-rpcs-staff.sql
--
-- Staff and manager RPCs. All require RBAC via assert_store_access() or
-- assert_store_manager(). Guard order throughout:
--   input → auth → rbac → lifecycle → membership → business rules →
--   advisory lock → mutation
--
-- Run order: AFTER 03-auth-helpers.sql.

-- ── award_points ──────────────────────────────────────────────────────────────
-- Records a points earn or redemption for an active member.
-- Positive p_points with p_rule_id: validated award rule.
-- Positive p_points without p_rule_id: free-form bonus, subject to max_bonus_points cap.
-- Negative p_points: redemption, must reference a redeem rule. Balance floor enforced.
-- Advisory lock serialises concurrent writes for the same (user, store) pair.
-- Lock is acquired AFTER all validation so rejected calls never hold a lock.

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
  -- input
  IF p_user_id  IS NULL THEN RAISE EXCEPTION 'missing user_id';  END IF;
  IF p_store_id IS NULL THEN RAISE EXCEPTION 'missing store_id'; END IF;
  IF p_points   IS NULL THEN RAISE EXCEPTION 'missing points';   END IF;
  IF p_reason   IS NULL THEN RAISE EXCEPTION 'missing reason';   END IF;
  -- auth
  IF v_staff_id IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  -- rbac
  PERFORM public.assert_store_access(p_store_id);
  -- lifecycle
  PERFORM public.assert_store_active(p_store_id);
  -- membership — staff cannot award to non-members or removed members
  PERFORM public.assert_active_membership(p_user_id, p_store_id);
  -- business rules
  IF p_points = 0 THEN RAISE EXCEPTION 'points cannot be zero'; END IF;

  IF p_points > 0 THEN
    IF p_rule_id IS NOT NULL THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.store_reward_rules
        WHERE id        = p_rule_id
          AND store_id  = p_store_id
          AND is_active = true
          AND kind      = 'award'
          AND points    = p_points
      ) THEN
        RAISE EXCEPTION 'invalid rule for this award';
      END IF;
    ELSE
      -- Free-form bonus award: check per-store cap if set
      SELECT max_bonus_points INTO v_max_bonus FROM public.stores WHERE id = p_store_id;
      IF v_max_bonus IS NOT NULL AND p_points > v_max_bonus THEN
        RAISE EXCEPTION 'exceeds bonus cap of % points for this store', v_max_bonus;
      END IF;
    END IF;
  ELSE
    -- Negative points = redemption; must reference a configured redeem rule
    IF p_rule_id IS NULL THEN
      RAISE EXCEPTION 'redemptions must reference a reward rule (p_rule_id required)';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.store_reward_rules
      WHERE id        = p_rule_id
        AND store_id  = p_store_id
        AND is_active = true
        AND kind      = 'redeem'
        AND points    = -p_points
    ) THEN
      RAISE EXCEPTION 'invalid rule for this redemption';
    END IF;
  END IF;

  IF p_outlet_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.store_outlets WHERE id = p_outlet_id AND store_id = p_store_id
    ) THEN
      RAISE EXCEPTION 'outlet does not belong to this store';
    END IF;
  END IF;

  -- advisory lock — transaction-scoped, releases on commit/rollback
  PERFORM pg_advisory_xact_lock(hashtext(p_user_id::text), hashtext(p_store_id::text));

  -- mutation
  SELECT running_balance INTO v_current_balance
  FROM   public.points_ledger
  WHERE  user_id  = p_user_id AND store_id = p_store_id
  ORDER  BY created_at DESC LIMIT 1;

  v_current_balance := COALESCE(v_current_balance, 0);
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
-- Manual correction path for staff. No rule validation, no bonus cap check.
-- NO balance floor — negative adjustments are intentional corrections and a
-- product requirement. Do not add a floor without an explicit decision.
-- Available to staff as well as managers (product requirement — do not restrict).

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
  -- input
  IF p_user_id  IS NULL THEN RAISE EXCEPTION 'missing user_id';  END IF;
  IF p_store_id IS NULL THEN RAISE EXCEPTION 'missing store_id'; END IF;
  IF p_points   IS NULL THEN RAISE EXCEPTION 'missing points';   END IF;
  IF p_reason   IS NULL THEN RAISE EXCEPTION 'missing reason';   END IF;
  -- auth
  IF v_staff_id IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  -- rbac
  PERFORM public.assert_store_access(p_store_id);
  -- lifecycle
  PERFORM public.assert_store_active(p_store_id);
  -- membership
  PERFORM public.assert_active_membership(p_user_id, p_store_id);
  -- business rules
  IF p_points = 0 THEN RAISE EXCEPTION 'points cannot be zero'; END IF;

  IF p_outlet_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.store_outlets WHERE id = p_outlet_id AND store_id = p_store_id
    ) THEN
      RAISE EXCEPTION 'outlet does not belong to this store';
    END IF;
  END IF;

  -- advisory lock — transaction-scoped, releases on commit/rollback
  PERFORM pg_advisory_xact_lock(hashtext(p_user_id::text), hashtext(p_store_id::text));

  -- mutation (no balance floor — by design)
  SELECT running_balance INTO v_current_balance
  FROM   public.points_ledger
  WHERE  user_id  = p_user_id AND store_id = p_store_id
  ORDER  BY created_at DESC LIMIT 1;

  v_current_balance := COALESCE(v_current_balance, 0);
  v_new_balance     := v_current_balance + p_points;

  INSERT INTO public.points_ledger
    (user_id, store_id, points, reason, created_by, running_balance, outlet_id)
  VALUES
    (p_user_id, p_store_id, p_points, p_reason, v_staff_id, v_new_balance, p_outlet_id);

  RETURN v_new_balance;
END $$;

-- ── load_store_members ────────────────────────────────────────────────────────
-- Returns all active members with current balance.
-- No assert_store_active — read-only; staff/managers may inspect archived stores.

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
           FROM   public.points_ledger pl
           WHERE  pl.user_id  = sm.user_id AND pl.store_id = p_store_id
           ORDER  BY pl.created_at DESC LIMIT 1),
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

-- ── load_store_staff_profiles ─────────────────────────────────────────────────
-- Returns staff roster with public IDs. Manager-only (staff lists reveal
-- organisational information that ordinary staff should not see).

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

-- ── load_store_outlets ────────────────────────────────────────────────────────
-- Returns outlets for the staff outlet picker. Accessible to staff and managers.

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

-- ── load_member_recent_transactions ───────────────────────────────────────────
-- Returns the last 5 ledger entries for one member at one store.
-- Returns only: points, reason, created_at — never exposes created_by or
-- running_balance. Server-side LIMIT 5 enforced.

CREATE OR REPLACE FUNCTION public.load_member_recent_transactions(
  p_user_id  uuid,
  p_store_id uuid
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM public.assert_store_access(p_store_id);

  RETURN (
    SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)
    FROM (
      SELECT points, reason, created_at
      FROM   public.points_ledger
      WHERE  user_id  = p_user_id
        AND  store_id = p_store_id
      ORDER  BY created_at DESC
      LIMIT  5
    ) t
  );
END $$;

-- ── approve_staff_applicant ───────────────────────────────────────────────────
-- Promotes an active member to staff. Requires manager/admin. Store must be
-- active. User must have an active membership. Name is legacy; this function
-- does not reference any applicant table.

CREATE OR REPLACE FUNCTION public.approve_staff_applicant(p_user_id uuid, p_store_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_user_id  IS NULL THEN RAISE EXCEPTION 'missing user_id';  END IF;
  IF p_store_id IS NULL THEN RAISE EXCEPTION 'missing store_id'; END IF;

  PERFORM public.assert_store_manager(p_store_id);
  PERFORM public.assert_store_active(p_store_id);
  PERFORM public.assert_active_membership(p_user_id, p_store_id);

  INSERT INTO public.store_staff (user_id, store_id)
  VALUES (p_user_id, p_store_id)
  ON CONFLICT DO NOTHING;

  RETURN json_build_object('success', true, 'user_id', p_user_id, 'store_id', p_store_id);
END $$;

-- ── demote_store_staff ────────────────────────────────────────────────────────
-- Removes a user from store_staff. Does not affect store_memberships (the user
-- remains a customer) or store_managers.

CREATE OR REPLACE FUNCTION public.demote_store_staff(p_user_id uuid, p_store_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_store_id IS NULL THEN RAISE EXCEPTION 'missing store_id'; END IF;
  IF p_user_id  IS NULL THEN RAISE EXCEPTION 'missing user_id';  END IF;

  PERFORM public.assert_store_manager(p_store_id);

  DELETE FROM public.store_staff
  WHERE user_id = p_user_id AND store_id = p_store_id;

  RETURN json_build_object('success', true, 'user_id', p_user_id, 'store_id', p_store_id);
END $$;

-- ── manager_remove_customer_from_store ────────────────────────────────────────
-- Soft-removes a customer by setting membership is_active = false.
-- Points history and running_balance are fully preserved.
-- Does not touch store_staff or store_managers rows.

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
  IF p_user_id  IS NULL THEN RAISE EXCEPTION 'missing user_id';  END IF;
  IF p_store_id IS NULL THEN RAISE EXCEPTION 'missing store_id'; END IF;

  PERFORM public.assert_store_manager(p_store_id);
  PERFORM public.assert_store_active(p_store_id);
  PERFORM public.assert_active_membership(p_user_id, p_store_id);

  UPDATE public.store_memberships
  SET    is_active = false
  WHERE  user_id  = p_user_id
    AND  store_id = p_store_id;

  RETURN json_build_object('success', true, 'user_id', p_user_id, 'store_id', p_store_id);
END $$;
