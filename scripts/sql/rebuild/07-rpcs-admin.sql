-- 07-rpcs-admin.sql
--
-- Admin-only RPCs and the admin_user_directory view.
-- Every function begins with: IF NOT public.is_admin() THEN RAISE EXCEPTION ...
-- Never inline the admin check — always call is_admin().
--
-- Run order: AFTER 03-auth-helpers.sql.
--
-- Audit: no functional changes required. The kind CHECK reduction in
-- 01-schema.sql (removing bonus_reason/bonus_amount) means
-- admin_insert_reward_rule now rejects those values at the DB constraint
-- level — no RPC code change is needed. The function still validates only
-- that p_kind IS NOT NULL; the schema enforces the allowed set.

-- ── admin_create_store ────────────────────────────────────────────────────────
-- Atomically creates a store AND a default 'Main' outlet in one transaction.
-- If outlet creation fails for any reason, the store INSERT is also rolled back.
-- Invariant: every store always has at least one outlet.

CREATE OR REPLACE FUNCTION public.admin_create_store(p_name text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_store  public.stores;
  v_outlet public.store_outlets;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF p_name IS NULL OR trim(p_name) = '' THEN RAISE EXCEPTION 'missing store name'; END IF;

  INSERT INTO public.stores (name)
  VALUES (trim(p_name))
  RETURNING * INTO v_store;

  INSERT INTO public.store_outlets (store_id, name)
  VALUES (v_store.id, 'Main')
  RETURNING * INTO v_outlet;

  RETURN json_build_object(
    'id',        v_store.id,
    'name',      v_store.name,
    'is_active', v_store.is_active,
    'outlet_id', v_outlet.id
  );
END $$;

-- ── admin_update_store ────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_update_store(p_store_id uuid, p_name text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_store public.stores;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF p_store_id IS NULL                    THEN RAISE EXCEPTION 'missing store_id';  END IF;
  IF p_name IS NULL OR trim(p_name) = ''   THEN RAISE EXCEPTION 'missing name';      END IF;

  UPDATE public.stores SET name = trim(p_name) WHERE id = p_store_id RETURNING * INTO v_store;
  IF NOT FOUND THEN RAISE EXCEPTION 'store not found'; END IF;

  RETURN row_to_json(v_store);
END $$;

-- ── admin_remove_store ────────────────────────────────────────────────────────
-- Hard delete — removes all associated data permanently.
-- Prefer admin_archive_store for reversible deactivation.
-- Explicit deletes are listed for auditability; ON DELETE CASCADE would handle
-- most of them automatically, but explicit is clearer.
-- This function is SECURITY DEFINER so it bypasses RESTRICTIVE RLS policies.

CREATE OR REPLACE FUNCTION public.admin_remove_store(p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF p_store_id IS NULL    THEN RAISE EXCEPTION 'missing store_id'; END IF;

  DELETE FROM public.points_ledger      WHERE store_id = p_store_id;
  DELETE FROM public.store_memberships  WHERE store_id = p_store_id;
  DELETE FROM public.store_staff        WHERE store_id = p_store_id;
  DELETE FROM public.store_managers     WHERE store_id = p_store_id;
  DELETE FROM public.store_reward_rules WHERE store_id = p_store_id;
  DELETE FROM public.store_outlets      WHERE store_id = p_store_id;
  DELETE FROM public.stores             WHERE id        = p_store_id;
END $$;

-- ── admin_archive_store ───────────────────────────────────────────────────────
-- Soft-delete: marks is_active = false, sets deleted_at. Reversible.
-- Both columns are set atomically to satisfy the schema CHECK:
--   CHECK (deleted_at IS NULL OR is_active = false)

CREATE OR REPLACE FUNCTION public.admin_archive_store(p_store_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF p_store_id IS NULL    THEN RAISE EXCEPTION 'missing store_id'; END IF;

  UPDATE public.stores
  SET    is_active  = false,
         deleted_at = now()
  WHERE  id = p_store_id;

  IF NOT FOUND THEN RAISE EXCEPTION 'store not found'; END IF;

  RETURN json_build_object('success', true, 'store_id', p_store_id);
END $$;

-- ── admin_restore_store ───────────────────────────────────────────────────────
-- Reverses an archive: marks is_active = true, clears deleted_at.
-- Both columns are set atomically to satisfy the schema CHECK.

CREATE OR REPLACE FUNCTION public.admin_restore_store(p_store_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF p_store_id IS NULL    THEN RAISE EXCEPTION 'missing store_id'; END IF;

  UPDATE public.stores
  SET    is_active  = true,
         deleted_at = NULL
  WHERE  id = p_store_id;

  IF NOT FOUND THEN RAISE EXCEPTION 'store not found'; END IF;

  RETURN json_build_object('success', true, 'store_id', p_store_id);
END $$;

-- ── admin_set_bonus_cap ───────────────────────────────────────────────────────
-- Sets or clears the per-store cap on free-form (no rule_id) bonus awards.
-- Pass NULL for p_max_bonus_points to remove the cap entirely.
-- The schema also enforces max_bonus_points >= 1 OR NULL; the RPC check here
-- is belt-and-suspenders with a cleaner error message.

CREATE OR REPLACE FUNCTION public.admin_set_bonus_cap(
  p_store_id         uuid,
  p_max_bonus_points integer
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF p_store_id IS NULL    THEN RAISE EXCEPTION 'missing store_id'; END IF;

  IF p_max_bonus_points IS NOT NULL AND p_max_bonus_points < 1 THEN
    RAISE EXCEPTION 'bonus cap must be at least 1';
  END IF;

  UPDATE public.stores SET max_bonus_points = p_max_bonus_points WHERE id = p_store_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'store not found'; END IF;
END $$;

-- ── admin_set_store_logo ──────────────────────────────────────────────────────
-- Updates logo_path and logo_updated_at atomically.
-- Path is validated server-side to prevent arbitrary storage paths being written.

CREATE OR REPLACE FUNCTION public.admin_set_store_logo(
  p_store_id  uuid,
  p_logo_path text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF p_store_id IS NULL    THEN RAISE EXCEPTION 'missing store_id'; END IF;

  IF p_logo_path IS DISTINCT FROM ('stores/' || p_store_id::text || '/logo.webp') THEN
    RAISE EXCEPTION 'invalid logo_path — must be stores/<store_id>/logo.webp';
  END IF;

  UPDATE public.stores
  SET    logo_path       = p_logo_path,
         logo_updated_at = now()
  WHERE  id = p_store_id;

  IF NOT FOUND THEN RAISE EXCEPTION 'store not found'; END IF;
END $$;

-- ── Reward rule RPCs ──────────────────────────────────────────────────────────
-- kind is validated by the schema CHECK (kind IN ('award', 'redeem')).
-- The RPC only validates that p_kind IS NOT NULL; invalid values are rejected
-- by the constraint with a clear PostgreSQL error.

CREATE OR REPLACE FUNCTION public.admin_insert_reward_rule(
  p_store_id   uuid,
  p_label      text,
  p_points     integer,
  p_kind       text,
  p_sort_order integer
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_rule public.store_reward_rules;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF p_store_id IS NULL    THEN RAISE EXCEPTION 'missing store_id'; END IF;
  IF p_label    IS NULL    THEN RAISE EXCEPTION 'missing label';    END IF;
  IF p_points   IS NULL    THEN RAISE EXCEPTION 'missing points';   END IF;
  IF p_kind     IS NULL    THEN RAISE EXCEPTION 'missing kind';     END IF;

  INSERT INTO public.store_reward_rules
    (store_id, label, points, kind, sort_order, is_active, is_pinned)
  VALUES
    (p_store_id, p_label, p_points, p_kind, COALESCE(p_sort_order, 0), true, false)
  RETURNING * INTO v_rule;

  RETURN row_to_json(v_rule);
END $$;

CREATE OR REPLACE FUNCTION public.admin_delete_reward_rule(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF p_id IS NULL          THEN RAISE EXCEPTION 'missing id';     END IF;

  DELETE FROM public.store_reward_rules WHERE id = p_id;
END $$;

CREATE OR REPLACE FUNCTION public.admin_update_reward_rule_order(p_id uuid, p_sort_order integer)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF p_id IS NULL          THEN RAISE EXCEPTION 'missing id';     END IF;

  UPDATE public.store_reward_rules SET sort_order = p_sort_order WHERE id = p_id;
END $$;

-- ── Outlet RPCs ───────────────────────────────────────────────────────────────
-- UNIQUE (store_id, name) is enforced at the schema level (01-schema.sql).
-- admin_create_outlet and admin_update_outlet will receive a constraint
-- violation error if a duplicate name is attempted within the same store.

CREATE OR REPLACE FUNCTION public.admin_create_outlet(p_store_id uuid, p_name text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_outlet public.store_outlets;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF p_store_id IS NULL    THEN RAISE EXCEPTION 'missing store_id'; END IF;
  IF p_name     IS NULL    THEN RAISE EXCEPTION 'missing name';     END IF;

  PERFORM public.assert_store_active(p_store_id);

  INSERT INTO public.store_outlets (store_id, name)
  VALUES (p_store_id, trim(p_name))
  RETURNING * INTO v_outlet;

  RETURN row_to_json(v_outlet);
END $$;

CREATE OR REPLACE FUNCTION public.admin_update_outlet(p_outlet_id uuid, p_name text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_outlet   public.store_outlets;
  v_store_id uuid;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF p_outlet_id IS NULL   THEN RAISE EXCEPTION 'missing outlet_id'; END IF;
  IF p_name      IS NULL   THEN RAISE EXCEPTION 'missing name';      END IF;

  SELECT store_id INTO v_store_id FROM public.store_outlets WHERE id = p_outlet_id;
  IF v_store_id IS NULL THEN RAISE EXCEPTION 'outlet not found'; END IF;

  PERFORM public.assert_store_active(v_store_id);

  UPDATE public.store_outlets
  SET    name = trim(p_name)
  WHERE  id   = p_outlet_id
  RETURNING * INTO v_outlet;

  RETURN row_to_json(v_outlet);
END $$;

-- admin_delete_outlet: last-outlet protection via advisory lock.
-- Concurrent delete requests for the same store are serialised by the lock so
-- neither can race past the count check and produce a zero-outlet store.
-- Lock namespace 1001 is distinct from the (user, store) advisory locks in
-- award_points / adjust_points to avoid false contention.

CREATE OR REPLACE FUNCTION public.admin_delete_outlet(p_outlet_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_store_id uuid;
  v_count    integer;
BEGIN
  IF NOT public.is_admin()  THEN RAISE EXCEPTION 'not authorized';    END IF;
  IF p_outlet_id IS NULL    THEN RAISE EXCEPTION 'missing outlet_id'; END IF;

  SELECT store_id INTO v_store_id
  FROM   public.store_outlets WHERE id = p_outlet_id;

  IF v_store_id IS NULL THEN RAISE EXCEPTION 'outlet not found'; END IF;

  -- Store-scoped advisory lock — transaction-scoped, auto-releases on commit/rollback.
  -- Count AFTER acquiring the lock (the authoritative check).
  PERFORM pg_advisory_xact_lock(1001, hashtext(v_store_id::text));

  SELECT COUNT(*) INTO v_count
  FROM   public.store_outlets WHERE store_id = v_store_id;

  IF v_count <= 1 THEN
    RAISE EXCEPTION 'cannot remove the last outlet — every store must have at least one';
  END IF;

  DELETE FROM public.store_outlets WHERE id = p_outlet_id;
END $$;

-- ── Staff and manager assignment ──────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_assign_staff(p_user_id uuid, p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'not authorized'; END IF;
  INSERT INTO public.store_staff (user_id, store_id) VALUES (p_user_id, p_store_id)
  ON CONFLICT DO NOTHING;
END $$;

CREATE OR REPLACE FUNCTION public.admin_remove_staff(p_user_id uuid, p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'not authorized'; END IF;
  DELETE FROM public.store_staff WHERE user_id = p_user_id AND store_id = p_store_id;
END $$;

CREATE OR REPLACE FUNCTION public.admin_assign_manager(p_user_id uuid, p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'not authorized'; END IF;
  INSERT INTO public.store_managers (user_id, store_id) VALUES (p_user_id, p_store_id)
  ON CONFLICT DO NOTHING;
END $$;

CREATE OR REPLACE FUNCTION public.admin_remove_manager(p_user_id uuid, p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'not authorized'; END IF;
  DELETE FROM public.store_managers WHERE user_id = p_user_id AND store_id = p_store_id;
END $$;

-- ── admin_load_store_members ──────────────────────────────────────────────────
-- Returns active member UUIDs for a store. Manager or admin only.
-- Cross-referenced with admin_user_directory for public IDs on the client.

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

-- ── admin_store_audit_log ─────────────────────────────────────────────────────
-- Returns the full points ledger for one store over the last p_days days,
-- with both the member's and the staff member's public_id included.
-- Admin-only for now. When the product is ready to expose this to managers,
-- replace IF NOT public.is_admin() with PERFORM public.assert_store_manager().
-- Re-run 08-grants.sql after that change — no other code needs updating.
--
-- Designed for weekly/monthly digest emails to store managers:
--   call with p_days = 7 for last week, p_days = 30 for last month.
-- Returns NULL created_by_public_id when the staff account has been deleted.

CREATE OR REPLACE FUNCTION public.admin_store_audit_log(
  p_store_id uuid,
  p_days     integer DEFAULT 7
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF p_store_id IS NULL    THEN RAISE EXCEPTION 'missing store_id'; END IF;
  IF p_days IS NULL OR p_days < 1 THEN RAISE EXCEPTION 'p_days must be at least 1'; END IF;

  RETURN (
    SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.created_at DESC), '[]'::json)
    FROM (
      SELECT
        pl.created_at,
        pl.points,
        pl.reason,
        member.public_id  AS member_public_id,
        staff.public_id   AS staff_public_id
      FROM   public.points_ledger pl
      LEFT JOIN public.profiles member ON member.user_id = pl.user_id
      LEFT JOIN public.profiles staff  ON staff.user_id  = pl.created_by
      WHERE  pl.store_id   = p_store_id
        AND  pl.created_at >= now() - (p_days || ' days')::interval
      ORDER  BY pl.created_at DESC
    ) t
  );
END $$;

-- ── admin_user_directory ──────────────────────────────────────────────────────
-- security_invoker = true: the view executes as the calling user, not the owner.
-- Non-admins see only their own profile row (RLS: "profiles: select own").
-- Admins see all rows (RLS: "profiles: select as admin").

DROP VIEW IF EXISTS public.admin_user_directory;
CREATE VIEW public.admin_user_directory
  WITH (security_invoker = true)
AS
  SELECT user_id, public_id
  FROM   public.profiles
  ORDER  BY public_id ASC NULLS LAST;
