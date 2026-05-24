-- ── add-soft-delete-v3.sql ────────────────────────────────────────────────────
--
-- Production-grade soft delete for stores + customer membership removal.
-- Supersedes add-soft-delete-v2.sql.
--
-- Improvements over v2:
--   - Two lifecycle helper functions centralise all repeated guard logic.
--   - Every mutation RPC follows the same strict check order:
--       1. auth            (auth.uid() / is_admin())
--       2. RBAC            (assert_store_access / assert_store_manager)
--       3. store lifecycle (assert_store_active)
--       4. business rules  (points, rule ids, outlet membership)
--       5. advisory lock   (only acquired after all validation passes)
--       6. mutation
--   - Advisory lock in award_points moved to just before the write; previously
--     it was held across all rule-validation queries unnecessarily.
--   - No function signatures changed. No business logic changed.
--
-- Structure:
--   schema → indexes → rls → helpers → new rpcs → updated rpcs → grants
--
-- Idempotent: safe to re-run.
-- Re-run fix-default-privileges.sql afterwards.

-- ── schema ────────────────────────────────────────────────────────────────────

ALTER TABLE public.stores
  ADD COLUMN IF NOT EXISTS is_active  boolean     NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz;

ALTER TABLE public.store_memberships
  ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true;

-- ── indexes ───────────────────────────────────────────────────────────────────

-- Supports the is_active = true filter added to every store lookup.
CREATE INDEX IF NOT EXISTS stores_is_active_idx
  ON public.stores (is_active);

-- Supports active-member queries in load_store_members and admin_load_store_members.
CREATE INDEX IF NOT EXISTS store_memberships_store_active_idx
  ON public.store_memberships (store_id, is_active);

-- Partial unique: at most one active membership per (user, store).
-- Complements the full unique constraint; makes the invariant explicit.
CREATE UNIQUE INDEX IF NOT EXISTS active_membership_unique
  ON public.store_memberships (user_id, store_id)
  WHERE is_active = true;

-- ── rls ───────────────────────────────────────────────────────────────────────

-- Inactive membership rows are now invisible to direct client queries.
-- All product read paths go through SECURITY DEFINER RPCs, so this is
-- defence-in-depth rather than a primary access control.
DROP POLICY IF EXISTS "memberships: select own" ON public.store_memberships;
CREATE POLICY "memberships: select own" ON public.store_memberships
  FOR SELECT USING (user_id = auth.uid() AND is_active = true);

-- ── helpers ───────────────────────────────────────────────────────────────────
-- Internal lifecycle guards called by every mutation RPC that touches a store
-- or its memberships. Centralises the repeated EXISTS checks from v2.

-- assert_store_active(p_store_id)
-- Raises if the store does not exist or has been archived (is_active = false).
-- Use after RBAC checks and before any business logic or advisory locks.

CREATE OR REPLACE FUNCTION public.assert_store_active(p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.stores WHERE id = p_store_id AND is_active = true
  ) THEN
    RAISE EXCEPTION 'store not found or archived';
  END IF;
END $$;

-- assert_active_membership(p_user_id, p_store_id)
-- Raises if no active membership row exists for the given (user, store) pair.
-- Use after assert_store_active and before mutations that require membership.

CREATE OR REPLACE FUNCTION public.assert_active_membership(p_user_id uuid, p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.store_memberships
    WHERE  user_id   = p_user_id
      AND  store_id  = p_store_id
      AND  is_active = true
  ) THEN
    RAISE EXCEPTION 'user is not an active member of this store';
  END IF;
END $$;

-- ── new rpcs: admin store lifecycle ──────────────────────────────────────────

-- admin_archive_store: sets is_active=false and records timestamp.
-- No assert_store_active here — this IS the lifecycle mutation.
-- IF NOT FOUND catches nonexistent store_ids.

CREATE OR REPLACE FUNCTION public.admin_archive_store(p_store_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_store_id IS NULL          THEN RAISE EXCEPTION 'missing store_id'; END IF;
  IF NOT public.is_admin()       THEN RAISE EXCEPTION 'Not authorized';   END IF;

  UPDATE public.stores
  SET    is_active  = false,
         deleted_at = now()
  WHERE  id = p_store_id;

  IF NOT FOUND THEN RAISE EXCEPTION 'store not found'; END IF;

  RETURN json_build_object('success', true, 'store_id', p_store_id);
END $$;

-- admin_restore_store: sets is_active=true and clears deleted_at.
-- No assert_store_active here — store is intentionally inactive on entry.

CREATE OR REPLACE FUNCTION public.admin_restore_store(p_store_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_store_id IS NULL    THEN RAISE EXCEPTION 'missing store_id'; END IF;
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Not authorized';   END IF;

  UPDATE public.stores
  SET    is_active  = true,
         deleted_at = NULL
  WHERE  id = p_store_id;

  IF NOT FOUND THEN RAISE EXCEPTION 'store not found'; END IF;

  RETURN json_build_object('success', true, 'store_id', p_store_id);
END $$;

-- ── new rpc: manager membership removal ──────────────────────────────────────

-- manager_remove_customer_from_store: soft-removes a customer by setting
-- their membership is_active=false. Points history is preserved. Staff/manager
-- table rows are not touched.
--
-- Check order:
--   1. null guards
--   2. RBAC   (assert_store_manager)
--   3. store  (assert_store_active)
--   4. membership (assert_active_membership)
--   5. update

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

-- ── updated rpcs ──────────────────────────────────────────────────────────────

-- join_store: blocks archived stores; reactivates a previously removed
-- membership via ON CONFLICT so removed customers can rejoin cleanly.
--
-- Check order:
--   1. auth   (v_user_id IS NULL)
--   2. store  (assert_store_active — no RBAC, customer-facing operation)
--   3. upsert

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

  IF v_user_id  IS NULL THEN RAISE EXCEPTION 'not authenticated';  END IF;
  IF p_store_id IS NULL THEN RAISE EXCEPTION 'missing store_id';   END IF;

  PERFORM public.assert_store_active(p_store_id);

  INSERT INTO public.store_memberships (user_id, store_id)
  VALUES (v_user_id, p_store_id)
  ON CONFLICT (user_id, store_id) DO UPDATE SET is_active = true;

  RETURN json_build_object('success', true, 'user_id', v_user_id, 'store_id', p_store_id);
END $$;

-- apply_for_staff: blocks archived stores. Previously had no store check.
--
-- Check order:
--   1. auth   (v_user_id IS NULL)
--   2. store  (assert_store_active — no RBAC, customer-facing operation)
--   3. insert

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

  IF v_user_id  IS NULL THEN RAISE EXCEPTION 'not authenticated';  END IF;
  IF p_store_id IS NULL THEN RAISE EXCEPTION 'missing store_id';   END IF;

  PERFORM public.assert_store_active(p_store_id);

  INSERT INTO public.store_staff_applicants (user_id, store_id)
  VALUES (v_user_id, p_store_id)
  ON CONFLICT (user_id, store_id) DO NOTHING;

  RETURN json_build_object('success', true, 'user_id', v_user_id, 'store_id', p_store_id);
END $$;

-- approve_staff_applicant: requires active store and active membership.
--
-- Check order:
--   1. null guards
--   2. RBAC       (assert_store_manager)
--   3. store      (assert_store_active)
--   4. membership (assert_active_membership)
--   5. insert

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

-- award_points: blocks archived stores.
--
-- Check order:
--   1. auth         (v_staff_id IS NULL)
--   2. RBAC         (assert_store_access)
--   3. store        (assert_store_active)
--   4. business     (zero check, rule/bonus validation, outlet validation)
--   5. advisory lock (acquired only after all validation passes)
--   6. mutation     (balance read → underflow check → insert)
--
-- v2 held the advisory lock across all rule-validation queries. v3 acquires
-- it only immediately before the read-modify-write, so rejected calls (wrong
-- rule id, bad outlet, zero points) never hold a lock.

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
  -- 1. auth
  IF v_staff_id IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;

  -- 2. RBAC
  PERFORM public.assert_store_access(p_store_id);

  -- 3. store lifecycle
  PERFORM public.assert_store_active(p_store_id);

  -- 4. business validation (no lock held yet — failed calls discard immediately)
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

  -- 5. advisory lock — transaction-scoped, released on commit/rollback
  PERFORM pg_advisory_xact_lock(hashtext(p_user_id::text), hashtext(p_store_id::text));

  -- 6. mutation
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

-- adjust_points: blocks archived stores.
--
-- Check order:
--   1. auth         (v_staff_id IS NULL)
--   2. RBAC         (assert_store_access)
--   3. store        (assert_store_active)
--   4. business     (zero check, outlet validation)
--   5. advisory lock
--   6. mutation     (balance read → insert)
--
-- v2 put the zero-points check before RBAC. Moved here to enforce strict order.

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
  -- 1. auth
  IF v_staff_id IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;

  -- 2. RBAC
  PERFORM public.assert_store_access(p_store_id);

  -- 3. store lifecycle
  PERFORM public.assert_store_active(p_store_id);

  -- 4. business validation
  IF p_points = 0 THEN RAISE EXCEPTION 'points cannot be zero'; END IF;

  IF p_outlet_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.store_outlets
      WHERE id = p_outlet_id AND store_id = p_store_id
    ) THEN
      RAISE EXCEPTION 'outlet does not belong to this store';
    END IF;
  END IF;

  -- 5. advisory lock — transaction-scoped, released on commit/rollback
  PERFORM pg_advisory_xact_lock(hashtext(p_user_id::text), hashtext(p_store_id::text));

  -- 6. mutation
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

-- admin_create_outlet: store check upgraded to require is_active = true.
--
-- Check order:
--   1. auth+RBAC  (is_admin() — combined for admin-only functions)
--   2. store      (assert_store_active)
--   3. insert

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

  PERFORM public.assert_store_active(p_store_id);

  INSERT INTO public.store_outlets (store_id, name)
  VALUES (p_store_id, trim(p_name))
  RETURNING * INTO v_outlet;

  RETURN row_to_json(v_outlet);
END $$;

-- load_store_members: returns only active members (is_active = true).
-- No assert_store_active — read-only; admins may inspect archived stores.

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

-- admin_load_store_members: returns only active members (is_active = true).
-- No assert_store_active — read-only; admins may inspect archived stores.

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

-- load_customer_home: filters out archived stores and inactive memberships
-- directly in the query. No assert_store_active — customer-facing read;
-- the WHERE clauses are the enforcement mechanism.

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

-- ── grants ────────────────────────────────────────────────────────────────────

-- Helpers: safe to expose — read-only validators, no mutations.
GRANT EXECUTE ON FUNCTION public.assert_store_active(uuid)              TO authenticated;
GRANT EXECUTE ON FUNCTION public.assert_active_membership(uuid, uuid)   TO authenticated;

-- New RPCs
GRANT EXECUTE ON FUNCTION public.admin_archive_store(uuid)                           TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_restore_store(uuid)                           TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_remove_customer_from_store(uuid, uuid)      TO authenticated;

-- Updated RPCs
GRANT EXECUTE ON FUNCTION public.join_store(uuid)                                    TO authenticated;
GRANT EXECUTE ON FUNCTION public.apply_for_staff(uuid)                               TO authenticated;
GRANT EXECUTE ON FUNCTION public.approve_staff_applicant(uuid, uuid)                 TO authenticated;
GRANT EXECUTE ON FUNCTION public.award_points(uuid, uuid, integer, text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.adjust_points(uuid, uuid, integer, text, uuid)      TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create_outlet(uuid, text)                     TO authenticated;
GRANT EXECUTE ON FUNCTION public.load_store_members(uuid)                            TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_load_store_members(uuid)                      TO authenticated;
GRANT EXECUTE ON FUNCTION public.load_customer_home(boolean)                         TO authenticated;

-- ── Re-run fix-default-privileges.sql after this script ──────────────────────
