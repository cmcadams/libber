-- 03-auth-helpers.sql
--
-- Authentication and RBAC helper functions. These are called by every mutation
-- RPC — they are the single source of truth for role checks.
--
-- Run order: AFTER 01-schema.sql. BEFORE 04-rls.sql (the profiles and
-- store_staff admin policies call is_admin() at RLS evaluation time).
--
-- All functions: SECURITY DEFINER SET search_path = ''.
-- is_admin() and get_store_role() are STABLE (pure reads, no side effects).

-- ── is_admin() ────────────────────────────────────────────────────────────────
-- Single source of admin truth. Every admin check in every RPC calls this.
-- Never inline the SELECT — always call is_admin().

CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
STABLE
AS $$
  SELECT EXISTS (SELECT 1 FROM public.admins WHERE user_id = auth.uid())
$$;

-- ── get_store_role() ──────────────────────────────────────────────────────────
-- Returns the caller's highest role at a store: 'admin' | 'manager' | 'staff' | NULL.
-- NULL means unauthenticated or no role at this store.
-- Checked in order of decreasing privilege so the highest role wins.

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
  IF EXISTS (SELECT 1 FROM public.admins         WHERE user_id = v_uid)                           THEN RETURN 'admin';   END IF;
  IF EXISTS (SELECT 1 FROM public.store_managers WHERE user_id = v_uid AND store_id = p_store_id) THEN RETURN 'manager'; END IF;
  IF EXISTS (SELECT 1 FROM public.store_staff    WHERE user_id = v_uid AND store_id = p_store_id) THEN RETURN 'staff';   END IF;
  RETURN null;
END $$;

-- ── assert_store_access() ─────────────────────────────────────────────────────
-- Passes for admin, manager, staff. Raises for unauthenticated or no role.
-- Use this for operations available to all store personnel (award, adjust, read).

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

-- ── assert_store_manager() ────────────────────────────────────────────────────
-- Passes for admin, manager. Raises for staff, unauthenticated, or no role.
-- COALESCE prevents NULL NOT IN (...) silently evaluating to NULL (falsy).

CREATE OR REPLACE FUNCTION public.assert_store_manager(p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF COALESCE(public.get_store_role(p_store_id), '') NOT IN ('manager', 'admin') THEN
    RAISE EXCEPTION 'not authorized: manager or admin access required for this store';
  END IF;
END $$;

-- ── assert_store_active() ─────────────────────────────────────────────────────
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

-- ── assert_active_membership() ────────────────────────────────────────────────
-- Raises if the (user, store) pair has no active membership row.
-- Call after assert_store_active, before mutations that require membership.
-- Prevents staff from awarding/adjusting points to non-members or removed users.

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
