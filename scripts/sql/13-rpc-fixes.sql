-- 13-rpc-fixes.sql
--
-- Audit patch: closes live functions missed by add-rbac-helpers.sql,
-- and adds the missing concurrency guard to adjust_points.
-- Based on fix-rbac-remaining.sql with reject_staff_applicant removed
-- (applicant system fully removed from rebuild).
--
-- Changes:
--   1. load_member_recent_transactions — replaces inline store_staff UNION
--      store_managers check with PERFORM assert_store_access.
--   2. [REMOVED — reject_staff_applicant referenced store_staff_applicants]
--   3. admin_load_store_members — replaces is_admin() OR EXISTS(store_managers)
--      WHERE-clause check with PERFORM assert_store_manager; converts from
--      LANGUAGE sql to plpgsql to support PERFORM.
--   4. adjust_points — adds pg_advisory_xact_lock to match award_points;
--      both functions read-then-write running_balance so both require the same
--      concurrency protection.
--
-- No business logic changes. No schema changes.
-- Safe to re-run — CREATE OR REPLACE throughout.
-- Run in Supabase SQL Editor (Dashboard → SQL Editor).
-- Re-run fix-default-privileges.sql afterwards.

-- ── 1. load_member_recent_transactions ───────────────────────────────────────

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

-- ── 2. [SKIPPED — reject_staff_applicant not in rebuild] ──────────────────────

-- ── 3. admin_load_store_members ───────────────────────────────────────────────
-- Converted from LANGUAGE sql to plpgsql so PERFORM assert_store_manager is usable.
-- Behaviour for authorized callers (admin/manager) is identical.
-- Unauthorized callers now receive a raised exception instead of an empty result
-- set — this is strictly safer and consistent with every other guarded RPC.
-- NOTE: overwritten by 14-soft-delete.sql with is_active filter on memberships.

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
    WHERE  sm.store_id = p_store_id;
END $$;

-- ── 4. adjust_points — add advisory lock ──────────────────────────────────────
-- Mirrors award_points exactly. Both functions read running_balance then insert;
-- without the lock, two concurrent calls for the same (user, store) pair can
-- read the same balance and produce duplicate or lost ledger rows.
-- NOTE: overwritten by 14-soft-delete.sql with assert_store_active + NULL guards.

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

  -- Serialize concurrent calls for the same (user, store) pair.
  -- Placed after auth so unauthorized requests are rejected before acquiring any lock.
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

-- ── Grants ────────────────────────────────────────────────────────────────────

GRANT EXECUTE ON FUNCTION public.load_member_recent_transactions(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_load_store_members(uuid)              TO authenticated;
GRANT EXECUTE ON FUNCTION public.adjust_points(uuid, uuid, integer, text, uuid) TO authenticated;

-- ── Re-run fix-default-privileges.sql after this script ──────────────────────
