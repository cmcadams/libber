-- ── 14-soft-delete.sql ────────────────────────────────────────────────────────
--
-- Soft delete for stores + customer membership removal.
-- Fixed rebuild version of add-soft-delete-v4.sql with:
--   - apply_for_staff REMOVED (applicant system fully removed)
--   - load_customer_home FIXED: restores logo_path + logo_updated_at from
--     add-store-logo.sql while keeping v4's is_active filters
--
-- No other business logic changes from v4.
-- Idempotent: safe to re-run.
-- Re-run fix-default-privileges.sql afterwards.
--
-- Sections:
--   schema · indexes · rls · helpers
--   rpc (admin lifecycle) · rpc (customer actions) · rpc (staff/admin actions)
--   grants

-- ── schema ────────────────────────────────────────────────────────────────────

ALTER TABLE public.stores
  ADD COLUMN IF NOT EXISTS is_active  boolean     NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz;

ALTER TABLE public.store_memberships
  ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true;

-- ── indexes ───────────────────────────────────────────────────────────────────

-- Covers the is_active filter on every store lookup.
CREATE INDEX IF NOT EXISTS stores_is_active_idx
  ON public.stores (is_active);

-- Covers the active-member filter in load_store_members / admin_load_store_members.
CREATE INDEX IF NOT EXISTS store_memberships_store_active_idx
  ON public.store_memberships (store_id, is_active);

-- Partial unique: at most one active membership row per (user, store).
-- Complements the full unique constraint; makes the invariant explicit.
CREATE UNIQUE INDEX IF NOT EXISTS active_membership_unique
  ON public.store_memberships (user_id, store_id)
  WHERE is_active = true;

-- ── rls ───────────────────────────────────────────────────────────────────────

-- Direct client queries on store_memberships will not see inactive rows.
-- All product read paths go through SECURITY DEFINER RPCs; this is
-- defence-in-depth rather than the primary access control.
DROP POLICY IF EXISTS "memberships: select own" ON public.store_memberships;
CREATE POLICY "memberships: select own" ON public.store_memberships
  FOR SELECT USING (user_id = auth.uid() AND is_active = true);

-- ── helpers ───────────────────────────────────────────────────────────────────
--
-- Two lifecycle guards called from every mutation RPC below.
-- Centralise the repeated EXISTS checks from earlier versions.
-- Both are SECURITY DEFINER and safe to expose to the authenticated role.

-- assert_store_active(p_store_id)
-- Raises if the store does not exist or is archived (is_active = false).
-- Call after RBAC checks, before business logic and advisory locks.

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
-- Raises if no active membership row exists for the (user, store) pair.
-- Call after assert_store_active, before mutations that require membership.

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

-- ── rpc (admin lifecycle) ─────────────────────────────────────────────────────
--
-- Store archive and restore. These ARE the lifecycle mutations, so
-- assert_store_active is intentionally absent — archive acts on an active
-- store, restore acts on an inactive one. IF NOT FOUND catches bad IDs.

-- admin_archive_store: marks a store inactive and records the timestamp.

CREATE OR REPLACE FUNCTION public.admin_archive_store(p_store_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- input
  IF p_store_id IS NULL    THEN RAISE EXCEPTION 'missing store_id'; END IF;
  -- auth (is_admin combines auth + rbac for admin-only functions)
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'not authorized';   END IF;
  -- mutation
  UPDATE public.stores
  SET    is_active  = false,
         deleted_at = now()
  WHERE  id = p_store_id;

  IF NOT FOUND THEN RAISE EXCEPTION 'store not found'; END IF;

  RETURN json_build_object('success', true, 'store_id', p_store_id);
END $$;

-- admin_restore_store: marks a store active and clears the deletion timestamp.

CREATE OR REPLACE FUNCTION public.admin_restore_store(p_store_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- input
  IF p_store_id IS NULL    THEN RAISE EXCEPTION 'missing store_id'; END IF;
  -- auth
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'not authorized';   END IF;
  -- mutation
  UPDATE public.stores
  SET    is_active  = true,
         deleted_at = NULL
  WHERE  id = p_store_id;

  IF NOT FOUND THEN RAISE EXCEPTION 'store not found'; END IF;

  RETURN json_build_object('success', true, 'store_id', p_store_id);
END $$;

-- ── rpc (customer actions) ────────────────────────────────────────────────────
--
-- Called by anonymous/authenticated customers. No RBAC check — auth.uid()
-- is the sole identity. assert_store_active guards against archived stores.

-- join_store: creates a membership, or reactivates one if the customer
-- previously left. Archived stores are rejected.

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
  -- auth
  IF v_user_id  IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  -- input
  IF p_store_id IS NULL THEN RAISE EXCEPTION 'missing store_id';  END IF;
  -- lifecycle
  PERFORM public.assert_store_active(p_store_id);
  -- mutation
  INSERT INTO public.store_memberships (user_id, store_id)
  VALUES (v_user_id, p_store_id)
  ON CONFLICT (user_id, store_id) DO UPDATE SET is_active = true;

  RETURN json_build_object('success', true, 'user_id', v_user_id, 'store_id', p_store_id);
END $$;

-- load_customer_home: returns profile, memberships with balances/rules/history,
-- and optionally the full store directory. Archived stores and inactive
-- memberships are excluded via WHERE clauses in the query itself.
-- Includes logo_path + logo_updated_at (restored from add-store-logo.sql).

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
  -- auth
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;

  SELECT public_id,
         save_prompt_variant,
         (account_linked_at IS NOT NULL)
  INTO   v_public_id, v_variant, v_account_linked
  FROM   public.profiles
  WHERE  user_id = v_user_id;

  -- query (is_active filters applied inline below)
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

-- ── rpc (staff/admin actions) ─────────────────────────────────────────────────
--
-- All functions in this section require RBAC (assert_store_access,
-- assert_store_manager, or is_admin). Every mutation follows the strict order:
--   input → auth → rbac → lifecycle → business rules → advisory lock → mutation

-- approve_staff_applicant: promotes an active member to staff.
-- Requires manager/admin. Store must be active. Membership must be active.
-- NOTE: name is legacy; function does NOT touch any applicant table.

CREATE OR REPLACE FUNCTION public.approve_staff_applicant(p_user_id uuid, p_store_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- input
  IF p_user_id  IS NULL THEN RAISE EXCEPTION 'missing user_id';  END IF;
  IF p_store_id IS NULL THEN RAISE EXCEPTION 'missing store_id'; END IF;
  -- rbac
  PERFORM public.assert_store_manager(p_store_id);
  -- lifecycle
  PERFORM public.assert_store_active(p_store_id);
  -- business rules
  PERFORM public.assert_active_membership(p_user_id, p_store_id);
  -- mutation
  INSERT INTO public.store_staff (user_id, store_id)
  VALUES (p_user_id, p_store_id)
  ON CONFLICT DO NOTHING;

  RETURN json_build_object('success', true, 'user_id', p_user_id, 'store_id', p_store_id);
END $$;

-- award_points: records a points earn or redemption for a customer.
-- Requires staff/manager/admin. Advisory lock serialises concurrent writes
-- for the same (user, store) pair and is acquired only after all validation
-- passes so rejected calls never hold a lock.

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

-- adjust_points: manual balance adjustment (admin / manager use).
-- No rule validation — caller supplies free-form reason and point delta.

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

-- manager_remove_customer_from_store: soft-removes a customer by setting
-- membership is_active=false. Points history is preserved entirely.
-- Staff/manager table rows are not touched.

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
  -- input
  IF p_user_id  IS NULL THEN RAISE EXCEPTION 'missing user_id';  END IF;
  IF p_store_id IS NULL THEN RAISE EXCEPTION 'missing store_id'; END IF;
  -- rbac
  PERFORM public.assert_store_manager(p_store_id);
  -- lifecycle
  PERFORM public.assert_store_active(p_store_id);
  -- business rules
  PERFORM public.assert_active_membership(p_user_id, p_store_id);
  -- mutation
  UPDATE public.store_memberships
  SET    is_active = false
  WHERE  user_id  = p_user_id
    AND  store_id = p_store_id;

  RETURN json_build_object('success', true, 'user_id', p_user_id, 'store_id', p_store_id);
END $$;

-- admin_create_outlet: adds an outlet to a store.
-- Archived stores are rejected — outlets exist to serve active stores.

CREATE OR REPLACE FUNCTION public.admin_create_outlet(p_store_id uuid, p_name text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_outlet public.store_outlets;
BEGIN
  -- input
  IF p_store_id IS NULL THEN RAISE EXCEPTION 'missing store_id'; END IF;
  IF p_name     IS NULL THEN RAISE EXCEPTION 'missing name';     END IF;
  -- auth
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'not authorized'; END IF;
  -- lifecycle
  PERFORM public.assert_store_active(p_store_id);
  -- mutation
  INSERT INTO public.store_outlets (store_id, name)
  VALUES (p_store_id, trim(p_name))
  RETURNING * INTO v_outlet;

  RETURN row_to_json(v_outlet);
END $$;

-- load_store_members: returns active members with current balance.
-- No assert_store_active — read-only; managers may inspect archived stores.

CREATE OR REPLACE FUNCTION public.load_store_members(p_store_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- rbac
  PERFORM public.assert_store_access(p_store_id);
  -- query
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

-- admin_load_store_members: returns active member user IDs.
-- No assert_store_active — read-only; managers may inspect archived stores.

CREATE OR REPLACE FUNCTION public.admin_load_store_members(p_store_id uuid)
RETURNS TABLE(user_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- rbac
  PERFORM public.assert_store_manager(p_store_id);
  -- query
  RETURN QUERY
    SELECT sm.user_id
    FROM   public.store_memberships sm
    WHERE  sm.store_id  = p_store_id
      AND  sm.is_active = true;
END $$;

-- ── grants ────────────────────────────────────────────────────────────────────

-- helpers
GRANT EXECUTE ON FUNCTION public.assert_store_active(uuid)            TO authenticated;
GRANT EXECUTE ON FUNCTION public.assert_active_membership(uuid, uuid) TO authenticated;

-- rpc (admin lifecycle)
GRANT EXECUTE ON FUNCTION public.admin_archive_store(uuid)            TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_restore_store(uuid)            TO authenticated;

-- rpc (customer actions)
GRANT EXECUTE ON FUNCTION public.join_store(uuid)                     TO authenticated;
GRANT EXECUTE ON FUNCTION public.load_customer_home(boolean)          TO authenticated;

-- rpc (staff/admin actions)
GRANT EXECUTE ON FUNCTION public.approve_staff_applicant(uuid, uuid)                 TO authenticated;
GRANT EXECUTE ON FUNCTION public.award_points(uuid, uuid, integer, text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.adjust_points(uuid, uuid, integer, text, uuid)      TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_remove_customer_from_store(uuid, uuid)      TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create_outlet(uuid, text)                     TO authenticated;
GRANT EXECUTE ON FUNCTION public.load_store_members(uuid)                            TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_load_store_members(uuid)                      TO authenticated;

-- ── Re-run fix-default-privileges.sql after this script ──────────────────────
