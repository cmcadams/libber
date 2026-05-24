-- ── fix-soft-delete-consistency.sql ───────────────────────────────────────────
--
-- Audit patch: closes all remaining soft-delete consistency gaps after
-- add-soft-delete.sql was applied.
--
-- RPCs modified (7 total):
--   1. award_points         — block transactions on archived stores
--   2. adjust_points        — block transactions on archived stores
--   3. join_store           — block joining an archived store
--   4. apply_for_staff      — block applying to an archived store
--   5. admin_create_outlet  — block adding outlets to an archived store
--   6. RLS memberships: select own — hide inactive memberships from direct queries
--   7. Indexes (3)          — performance + safety
--
-- No signature changes. No schema changes. No RBAC model changes.
-- Safe to re-run — CREATE OR REPLACE + DROP/CREATE POLICY + IF NOT EXISTS.
-- Re-run fix-default-privileges.sql afterwards.

-- ── 1. Indexes ────────────────────────────────────────────────────────────────

-- Fast filter for archived/active store lookups.
CREATE INDEX IF NOT EXISTS stores_is_active_idx
  ON public.stores (is_active);

-- Fast filter for "active members of store X" — used by load_store_members and
-- admin_load_store_members on every Manage Store load.
CREATE INDEX IF NOT EXISTS store_memberships_store_active_idx
  ON public.store_memberships (store_id, is_active);

-- Partial unique index: at most one active membership per (user, store).
-- Redundant with the full unique constraint but makes the invariant explicit
-- and enables the partial-index fast path in Postgres.
CREATE UNIQUE INDEX IF NOT EXISTS active_membership_unique
  ON public.store_memberships (user_id, store_id)
  WHERE is_active = true;

-- ── 2. RLS: hide inactive memberships from direct client queries ──────────────
-- The existing policy allowed users to see rows where user_id = auth.uid(),
-- including is_active = false rows. Since all read paths go through SECURITY
-- DEFINER RPCs this was not a data leak in practice, but adds defence in depth.

DROP POLICY IF EXISTS "memberships: select own" ON public.store_memberships;
CREATE POLICY "memberships: select own" ON public.store_memberships
  FOR SELECT USING (user_id = auth.uid() AND is_active = true);

-- ── 3. award_points — block transactions on archived stores ───────────────────
-- Gap: assert_store_access checks the caller's role but not the store's
-- is_active flag. Staff at an archived store could still call award_points.
-- Fix: explicit is_active guard inserted between assert_store_access and the
-- advisory lock so unauthorized requests are rejected before any lock is held.

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

  -- Reject if store is archived.
  IF NOT EXISTS (
    SELECT 1 FROM public.stores WHERE id = p_store_id AND is_active = true
  ) THEN
    RAISE EXCEPTION 'store is archived and not accepting transactions';
  END IF;

  -- Serialize concurrent calls for the same (user, store) pair.
  -- Placed after auth + store checks so rejected calls never acquire a lock.
  -- Transaction-scoped: released automatically on commit or rollback.
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

  -- Validate outlet belongs to this store if provided.
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

-- ── 4. adjust_points — block transactions on archived stores ──────────────────
-- Same gap and same fix as award_points. Reproduces the full function from
-- fix-rbac-remaining.sql (including the pg_advisory_xact_lock) with the
-- is_active guard inserted in the same position.

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

  -- Reject if store is archived.
  IF NOT EXISTS (
    SELECT 1 FROM public.stores WHERE id = p_store_id AND is_active = true
  ) THEN
    RAISE EXCEPTION 'store is archived and not accepting transactions';
  END IF;

  -- Serialize concurrent calls for the same (user, store) pair.
  PERFORM pg_advisory_xact_lock(hashtext(p_user_id::text), hashtext(p_store_id::text));

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

-- ── 5. join_store — block joining an archived store ───────────────────────────
-- Gap: add-soft-delete.sql changed the ON CONFLICT to re-activate memberships
-- but did not add a check that the target store is active. A customer could
-- call join_store on an archived store and the membership would be inserted or
-- re-activated.

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
  IF p_store_id IS NULL THEN RAISE EXCEPTION 'missing store_id'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.stores WHERE id = p_store_id AND is_active = true
  ) THEN
    RAISE EXCEPTION 'store not found or not accepting new members';
  END IF;

  INSERT INTO public.store_memberships (user_id, store_id)
  VALUES (v_user_id, p_store_id)
  ON CONFLICT (user_id, store_id) DO UPDATE SET is_active = true;

  RETURN json_build_object('success', true, 'user_id', v_user_id, 'store_id', p_store_id);
END $$;

-- ── 6. apply_for_staff — block applying to an archived store ─────────────────
-- Gap: apply_for_staff had no store existence check at all, let alone an
-- is_active check. A customer could submit a staff application to an archived
-- store.

CREATE OR REPLACE FUNCTION public.apply_for_staff(p_store_id uuid)
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
  IF p_store_id IS NULL THEN RAISE EXCEPTION 'missing store_id'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.stores WHERE id = p_store_id AND is_active = true
  ) THEN
    RAISE EXCEPTION 'store not found or not available';
  END IF;

  INSERT INTO public.store_staff_applicants (user_id, store_id)
  VALUES (v_user_id, p_store_id)
  ON CONFLICT (user_id, store_id) DO NOTHING;

  RETURN json_build_object('success', true, 'user_id', v_user_id, 'store_id', p_store_id);
END $$;

-- ── 7. admin_create_outlet — block adding outlets to an archived store ────────
-- Gap: the store-existence check was `WHERE id = p_store_id` with no is_active
-- filter. An admin could add outlets to an archived store.

CREATE OR REPLACE FUNCTION public.admin_create_outlet(p_store_id uuid, p_name text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_outlet public.store_outlets;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.stores WHERE id = p_store_id AND is_active = true
  ) THEN
    RAISE EXCEPTION 'Store not found or archived';
  END IF;

  INSERT INTO public.store_outlets (store_id, name)
  VALUES (p_store_id, trim(p_name))
  RETURNING * INTO v_outlet;

  RETURN row_to_json(v_outlet);
END $$;

-- ── Grants (idempotent) ───────────────────────────────────────────────────────

GRANT EXECUTE ON FUNCTION public.award_points(uuid, uuid, integer, text, uuid, uuid)   TO authenticated;
GRANT EXECUTE ON FUNCTION public.adjust_points(uuid, uuid, integer, text, uuid)        TO authenticated;
GRANT EXECUTE ON FUNCTION public.join_store(uuid)                                      TO authenticated;
GRANT EXECUTE ON FUNCTION public.apply_for_staff(uuid)                                 TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create_outlet(uuid, text)                       TO authenticated;

-- ── Re-run fix-default-privileges.sql after this script ──────────────────────
