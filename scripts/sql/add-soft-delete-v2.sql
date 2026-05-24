-- ── add-soft-delete-v2.sql ────────────────────────────────────────────────────
--
-- Soft delete for stores + customer membership removal.
-- Merges add-soft-delete.sql and fix-soft-delete-consistency.sql into one
-- atomic, fully-consistent migration.
--
-- Schema:
--   stores.is_active boolean NOT NULL DEFAULT true
--   stores.deleted_at timestamptz
--   store_memberships.is_active boolean NOT NULL DEFAULT true
--
-- New RPCs:
--   admin_archive_store(p_store_id)
--   admin_restore_store(p_store_id)
--   manager_remove_customer_from_store(p_user_id, p_store_id)
--
-- Updated RPCs (existing signatures unchanged):
--   join_store              — blocks archived stores; reactivates on re-join
--   apply_for_staff         — blocks archived stores
--   approve_staff_applicant — requires active membership
--   award_points            — blocks archived stores
--   adjust_points           — blocks archived stores
--   admin_create_outlet     — blocks archived stores
--   load_store_members      — filters is_active = true memberships
--   admin_load_store_members — filters is_active = true memberships
--   load_customer_home      — filters archived stores + inactive memberships
--
-- RLS:
--   memberships: select own — updated to include AND is_active = true
--
-- Idempotent: safe to re-run.
-- Re-run fix-default-privileges.sql afterwards.

-- ── 1. Schema ─────────────────────────────────────────────────────────────────

ALTER TABLE public.stores
  ADD COLUMN IF NOT EXISTS is_active  boolean     NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz;

ALTER TABLE public.store_memberships
  ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true;

-- ── 2. Indexes ────────────────────────────────────────────────────────────────

-- Fast filter for archived/active store lookups used across multiple RPCs.
CREATE INDEX IF NOT EXISTS stores_is_active_idx
  ON public.stores (is_active);

-- Fast filter for "active members of store X" — used on every Manage Store load.
CREATE INDEX IF NOT EXISTS store_memberships_store_active_idx
  ON public.store_memberships (store_id, is_active);

-- Partial unique index: at most one active membership per (user, store).
-- Redundant with the full unique constraint but makes the invariant explicit
-- and enables the partial-index fast path in Postgres.
CREATE UNIQUE INDEX IF NOT EXISTS active_membership_unique
  ON public.store_memberships (user_id, store_id)
  WHERE is_active = true;

-- ── 3. RLS ────────────────────────────────────────────────────────────────────

-- Hide inactive membership rows from direct client queries.
-- All read paths go through SECURITY DEFINER RPCs so this adds defence in depth.
DROP POLICY IF EXISTS "memberships: select own" ON public.store_memberships;
CREATE POLICY "memberships: select own" ON public.store_memberships
  FOR SELECT USING (user_id = auth.uid() AND is_active = true);

-- ── 4. admin_archive_store ────────────────────────────────────────────────────
-- Sets is_active=false and records deletion time. No data is deleted.

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

-- ── 5. admin_restore_store ────────────────────────────────────────────────────

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

-- ── 6. manager_remove_customer_from_store ────────────────────────────────────
-- Soft-removes a customer by setting membership is_active=false.
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

-- ── 7. join_store ─────────────────────────────────────────────────────────────
-- Blocks archived stores. Reactivates a previously removed membership via
-- ON CONFLICT so a removed customer can rejoin cleanly.

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

-- ── 8. apply_for_staff ────────────────────────────────────────────────────────
-- Blocks archived stores. Previously had no store existence check at all.

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

-- ── 9. approve_staff_applicant ────────────────────────────────────────────────
-- Membership check now requires is_active = true.

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

-- ── 10. award_points ──────────────────────────────────────────────────────────
-- Blocks archived stores. Check inserted after assert_store_access and before
-- the advisory lock so rejected calls never acquire a lock.

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

-- ── 11. adjust_points ─────────────────────────────────────────────────────────
-- Blocks archived stores. Includes pg_advisory_xact_lock from fix-rbac-remaining.

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

  IF NOT EXISTS (
    SELECT 1 FROM public.stores WHERE id = p_store_id AND is_active = true
  ) THEN
    RAISE EXCEPTION 'store is archived and not accepting transactions';
  END IF;

  -- Serialize concurrent calls for the same (user, store) pair.
  -- Transaction-scoped: released automatically on commit or rollback.
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

-- ── 12. admin_create_outlet ───────────────────────────────────────────────────
-- Store existence check now requires is_active = true.

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

-- ── 13. load_store_members ────────────────────────────────────────────────────
-- Filters is_active = true so removed customers are not shown to staff.

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

-- ── 14. admin_load_store_members ──────────────────────────────────────────────
-- Filters is_active = true so removed customers are not shown to managers/admins.

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

-- ── 15. load_customer_home ────────────────────────────────────────────────────
-- Filters:
--   sm.is_active = true  — hide memberships the customer was removed from
--   s.is_active  = true  — hide archived stores from the membership list
--   WHERE is_active = true — hide archived stores from the browse list

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

-- ── 16. Grants ────────────────────────────────────────────────────────────────

GRANT EXECUTE ON FUNCTION public.admin_archive_store(uuid)                             TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_restore_store(uuid)                             TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_remove_customer_from_store(uuid, uuid)        TO authenticated;
GRANT EXECUTE ON FUNCTION public.join_store(uuid)                                      TO authenticated;
GRANT EXECUTE ON FUNCTION public.apply_for_staff(uuid)                                 TO authenticated;
GRANT EXECUTE ON FUNCTION public.approve_staff_applicant(uuid, uuid)                   TO authenticated;
GRANT EXECUTE ON FUNCTION public.award_points(uuid, uuid, integer, text, uuid, uuid)   TO authenticated;
GRANT EXECUTE ON FUNCTION public.adjust_points(uuid, uuid, integer, text, uuid)        TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create_outlet(uuid, text)                       TO authenticated;
GRANT EXECUTE ON FUNCTION public.load_store_members(uuid)                              TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_load_store_members(uuid)                        TO authenticated;
GRANT EXECUTE ON FUNCTION public.load_customer_home(boolean)                           TO authenticated;

-- ── Re-run fix-default-privileges.sql after this script ──────────────────────
