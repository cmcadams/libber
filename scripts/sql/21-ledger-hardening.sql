-- 21-ledger-hardening.sql
--
-- Production hardening of points_ledger — closes the critical and high
-- findings from the security audit.
--
-- Changes (in order of severity):
--
--   1. RESTRICTIVE UPDATE and DELETE policies on points_ledger.
--      Closes the defense-in-depth gap: today authenticated holds no UPDATE/
--      DELETE privilege on points_ledger, but there was no RLS safety net to
--      catch a future accidental GRANT. These policies make direct ledger
--      mutation impossible even if table privileges are ever widened by mistake.
--      Pattern mirrors stores, store_reward_rules, store_outlets.
--
--   2. load_points_history(p_store_id uuid) — new SECURITY DEFINER RPC.
--      Replaces the direct supabase.from('points_ledger').select(...) call in
--      src/ui/renderUser.js (toggleHistory). Enforces identity via auth.uid()
--      internally. Returns only: points, reason, created_at. Never exposes
--      created_by, running_balance, outlet_id, or any internal metadata.
--      After the frontend is updated, the only direct-access path that remains
--      on points_ledger is the realtime subscription — retained deliberately
--      (see note below).
--
--   3. award_points — adds assert_active_membership(p_user_id, p_store_id).
--      Replaces the version from 14-soft-delete.sql. Staff can no longer award
--      points to non-members, removed members, or arbitrary UUIDs. The check
--      runs after assert_store_active (store must be active before its
--      memberships are meaningful) and before the advisory lock (reject invalid
--      requests before acquiring any lock).
--
--   4. adjust_points — adds assert_active_membership(p_user_id, p_store_id).
--      Replaces the version from 14-soft-delete.sql. Staff retain full access
--      to adjust_points (product requirement). No balance floor is added —
--      staff corrections are intentionally uncapped in the negative direction.
--      If a floor is needed in future, add it here with a new migration.
--
-- What is intentionally NOT changed:
--
--   SELECT on points_ledger is retained for authenticated.
--   The realtime subscription (11-security-hardening.sql) requires the
--   authenticated role to be able to read its own rows for the RLS check
--   that Supabase Realtime applies per-event. Without this grant, INSERT
--   events would not be delivered to the subscriber.
--   The subscription is already safe: RLS (user_id = auth.uid()) restricts
--   delivery to each user's own rows. The frontend callback in customer/main.js
--   ignores payload.new entirely and calls load_customer_home() on receipt.
--   The created_by column is in the WAL payload but not consumed by any client
--   code. Restricting the publication column list (PostgreSQL 15+ feature) is
--   a future hardening step once Supabase column-list publication support is
--   confirmed stable in this project's environment.
--
-- Depends on:
--   00-base-schema.sql (points_ledger table)
--   10-rbac-helpers.sql (assert_store_access, get_store_role)
--   14-soft-delete.sql (assert_store_active, assert_active_membership,
--                       award_points, adjust_points — overwritten here)
--
-- Safe to re-run: yes — DROP POLICY IF EXISTS + CREATE OR REPLACE throughout.
-- Re-run 15-final-grants.sql after this migration.

-- ── 1. RESTRICTIVE UPDATE and DELETE on points_ledger ─────────────────────────
--
-- Defense-in-depth against future accidental GRANT UPDATE/DELETE.
-- These policies make it structurally impossible for direct client mutations
-- to succeed even if table-level privileges are widened.

DROP POLICY IF EXISTS "ledger: no direct update" ON public.points_ledger;
DROP POLICY IF EXISTS "ledger: no direct delete" ON public.points_ledger;

CREATE POLICY "ledger: no direct update" ON public.points_ledger
  AS RESTRICTIVE FOR UPDATE USING (false);

CREATE POLICY "ledger: no direct delete" ON public.points_ledger
  AS RESTRICTIVE FOR DELETE USING (false);

-- ── 2. load_points_history — customer self-read via SECURITY DEFINER RPC ──────
--
-- Replaces direct supabase.from('points_ledger').select(...) in the frontend.
--
-- Security properties:
--   - Identity enforced by auth.uid() inside the function — caller cannot pass
--     a different user_id.
--   - Returns only the three columns the customer UI needs: points, reason,
--     created_at. created_by, running_balance, and outlet_id are never exposed.
--   - p_store_id scopes the query — a customer cannot use this RPC to read
--     history across stores they do not control (and the WHERE clause enforces
--     user_id = auth.uid() regardless).
--   - COALESCE to '[]' means callers always receive an array; null check not
--     needed in the frontend.

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
  -- auth
  IF v_user_id  IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  -- input
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

GRANT EXECUTE ON FUNCTION public.load_points_history(uuid) TO authenticated;

-- ── 3. award_points — add assert_active_membership ───────────────────────────
--
-- Adds membership validation: staff can no longer award points to non-members,
-- users whose membership is inactive, or arbitrary auth.users UUIDs.
-- All other logic is unchanged from 14-soft-delete.sql.
-- Replaces the version in 14-soft-delete.sql.
--
-- Guard order (follows the convention in MIGRATIONS.md):
--   input → auth → rbac → lifecycle → membership → business rules →
--   advisory lock → mutation

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
  -- membership (added in 21-ledger-hardening.sql)
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
      SELECT 1 FROM public.store_outlets
      WHERE id = p_outlet_id AND store_id = p_store_id
    ) THEN
      RAISE EXCEPTION 'outlet does not belong to this store';
    END IF;
  END IF;
  -- advisory lock (transaction-scoped; released on commit/rollback)
  PERFORM pg_advisory_xact_lock(hashtext(p_user_id::text), hashtext(p_store_id::text));
  -- mutation
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

GRANT EXECUTE ON FUNCTION public.award_points(uuid, uuid, integer, text, uuid, uuid) TO authenticated;

-- ── 4. adjust_points — add assert_active_membership ──────────────────────────
--
-- Adds membership validation: staff can no longer adjust points for non-members
-- or users whose membership is inactive.
--
-- Product requirements preserved:
--   - Staff retain access (assert_store_access, not assert_store_manager).
--   - No balance floor — negative adjustments are intentional corrections.
--   - No rule reference required — adjust_points is the free-form path.
--
-- Replaces the version in 14-soft-delete.sql.

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
  -- membership (added in 21-ledger-hardening.sql)
  PERFORM public.assert_active_membership(p_user_id, p_store_id);
  -- business rules
  IF p_points = 0 THEN RAISE EXCEPTION 'points cannot be zero'; END IF;

  IF p_outlet_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.store_outlets
      WHERE id = p_outlet_id AND store_id = p_store_id
    ) THEN
      RAISE EXCEPTION 'outlet does not belong to this store';
    END IF;
  END IF;
  -- advisory lock (transaction-scoped; released on commit/rollback)
  PERFORM pg_advisory_xact_lock(hashtext(p_user_id::text), hashtext(p_store_id::text));
  -- mutation
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

GRANT EXECUTE ON FUNCTION public.adjust_points(uuid, uuid, integer, text, uuid) TO authenticated;

-- ── Re-run 15-final-grants.sql after this migration ───────────────────────────
