-- 17-outlet-integrity.sql
--
-- Enforces the invariant: every store must always have at least one outlet.
--
-- Changes:
--   1. admin_create_store — atomically inserts a default 'Main' outlet in the
--      same transaction as the store. If outlet creation fails for any reason,
--      the store INSERT is also rolled back. Returns outlet_id alongside store fields.
--      Replaces the version in 01-admin-security.sql.
--
--   2. admin_delete_outlet — acquires a store-scoped advisory lock before
--      counting outlets and deleting, preventing two concurrent deletes from
--      both passing the count check and producing a zero-outlet store.
--      Raises a clean error if the outlet is the last one.
--      Replaces the version in 14-soft-delete.sql (which replaced 06-schema-outlets.sql).
--
--   3. Backfill — inserts a 'Main' outlet for any store that currently has none,
--      bringing pre-existing stores into compliance with the new invariant.
--
-- Depends on:
--   00-base-schema.sql (stores table)
--   06-schema-outlets.sql (store_outlets table)
--   01-admin-security.sql (is_admin(), admin_create_store)
--
-- Safe to re-run: yes.
-- Re-run 15-final-grants.sql after this script.

-- ── 1. admin_create_store: atomic store + default outlet ──────────────────────
--
-- Security: is_admin() checked first. Both INSERTs run inside one plpgsql
-- function which is already a single transaction. No explicit BEGIN/COMMIT
-- needed — plpgsql functions are transactional by default in Supabase/pg.
--
-- The outlet INSERT uses the store's UUID returned from RETURNING *, so
-- there is no window between store creation and outlet creation where the
-- store could exist with zero outlets.

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
  -- auth
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'not authorized'; END IF;
  -- input
  IF p_name IS NULL OR trim(p_name) = '' THEN RAISE EXCEPTION 'missing store name'; END IF;

  -- mutation (both in the same transaction — outlet failure rolls back store)
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

GRANT EXECUTE ON FUNCTION public.admin_create_store(text) TO authenticated;


-- ── 2. admin_delete_outlet: last-outlet protection ────────────────────────────
--
-- Security design:
--   a) is_admin() check before any data access.
--   b) Resolve store_id from p_outlet_id (confirms outlet exists and belongs
--      to a store; avoids leaking store info to non-admins since is_admin()
--      has already passed at this point).
--   c) Advisory lock scoped to the store using namespace 1001. This prevents
--      two concurrent DELETE calls from both reading count = 2 and both
--      proceeding to delete, which would leave the store with zero outlets.
--      The lock is transaction-scoped (_xact_) and releases automatically on
--      commit or rollback.
--      Namespace 1001 was chosen to avoid collision with the (user_hash,
--      store_hash) advisory locks used in award_points / adjust_points.
--   d) Count check AFTER acquiring the lock — not before.
--   e) DELETE only if count > 1.
--
-- No race condition because:
--   - Concurrent Req A and Req B both enter this function for the same store.
--   - One acquires pg_advisory_xact_lock(1001, hashtext(store_id)) first; the
--     other blocks until the first transaction commits.
--   - When the blocked transaction resumes, it re-counts and sees count = 1,
--     then raises the exception.

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
  -- input
  IF p_outlet_id IS NULL THEN RAISE EXCEPTION 'missing outlet_id'; END IF;
  -- auth
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'not authorized'; END IF;

  -- resolve store (also confirms outlet exists)
  SELECT store_id INTO v_store_id
  FROM   public.store_outlets
  WHERE  id = p_outlet_id;

  IF v_store_id IS NULL THEN RAISE EXCEPTION 'outlet not found'; END IF;

  -- store-scoped advisory lock (transaction-scoped; releases on commit/rollback)
  -- namespace 1001 avoids collision with award_points advisory locks
  PERFORM pg_advisory_xact_lock(1001, hashtext(v_store_id::text));

  -- count AFTER the lock — this is the authoritative check
  SELECT COUNT(*) INTO v_count
  FROM   public.store_outlets
  WHERE  store_id = v_store_id;

  IF v_count <= 1 THEN
    RAISE EXCEPTION 'Cannot remove the last outlet — every store must have at least one.';
  END IF;

  DELETE FROM public.store_outlets WHERE id = p_outlet_id;
END $$;

GRANT EXECUTE ON FUNCTION public.admin_delete_outlet(uuid) TO authenticated;


-- ── 3. Backfill: add 'Main' outlet to stores with none ───────────────────────
--
-- Brings pre-existing stores into compliance with the new invariant.
-- Safe to re-run: the subquery prevents inserting if an outlet already exists.

INSERT INTO public.store_outlets (store_id, name)
SELECT s.id, 'Main'
FROM   public.stores s
WHERE  NOT EXISTS (
  SELECT 1 FROM public.store_outlets o WHERE o.store_id = s.id
);

-- ── Re-run 15-final-grants.sql after this script ─────────────────────────────
