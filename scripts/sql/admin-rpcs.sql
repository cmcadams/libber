-- Admin RPCs and security hardening.
-- Safe to re-run — all statements are idempotent.
-- Run in the Supabase SQL Editor (Dashboard → SQL Editor).
--
-- Fixes two open security gaps:
--   1. stores INSERT was open to any authenticated user
--   2. store_reward_rules INSERT/DELETE was open to any authenticated user
--
-- Approach: create an admins table, add an is_admin() check inside each
-- admin RPC, and block direct client writes to stores and store_reward_rules.
-- All other tables are left untouched.

-- ── Admins table ──────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.admins (
  user_id    uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at timestamptz DEFAULT now()
);

ALTER TABLE public.admins ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "admins: service role only" ON public.admins;
CREATE POLICY "admins: service role only" ON public.admins
  USING (auth.role() = 'service_role');

-- ── is_admin() helper ─────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
STABLE
AS $$
  SELECT EXISTS (SELECT 1 FROM public.admins WHERE user_id = auth.uid())
$$;

-- ── RLS: block direct client writes to stores ─────────────────────────────────

ALTER TABLE public.stores ENABLE ROW LEVEL SECURITY;

-- stores has no SELECT policy — add one before enabling RLS or reads break.
DROP POLICY IF EXISTS "stores: allow select" ON public.stores;
CREATE POLICY "stores: allow select" ON public.stores FOR SELECT USING (true);

DROP POLICY IF EXISTS "stores: no direct insert" ON public.stores;
DROP POLICY IF EXISTS "stores: no direct update" ON public.stores;
DROP POLICY IF EXISTS "stores: no direct delete" ON public.stores;

CREATE POLICY "stores: no direct insert" ON public.stores AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY "stores: no direct update" ON public.stores AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY "stores: no direct delete" ON public.stores AS RESTRICTIVE FOR DELETE USING (false);

-- ── RLS: block direct client writes to store_reward_rules ────────────────────

ALTER TABLE public.store_reward_rules ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "rules: no direct insert" ON public.store_reward_rules;
DROP POLICY IF EXISTS "rules: no direct update" ON public.store_reward_rules;
DROP POLICY IF EXISTS "rules: no direct delete" ON public.store_reward_rules;

CREATE POLICY "rules: no direct insert" ON public.store_reward_rules AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY "rules: no direct update" ON public.store_reward_rules AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY "rules: no direct delete" ON public.store_reward_rules AS RESTRICTIVE FOR DELETE USING (false);

-- ── Admin RPCs for stores ─────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_create_store(p_name text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_store public.stores;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  INSERT INTO public.stores (name) VALUES (trim(p_name)) RETURNING * INTO v_store;
  RETURN row_to_json(v_store);
END $$;

CREATE OR REPLACE FUNCTION public.admin_update_store(p_store_id uuid, p_name text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_store public.stores;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  UPDATE public.stores SET name = trim(p_name) WHERE id = p_store_id RETURNING * INTO v_store;
  RETURN row_to_json(v_store);
END $$;

CREATE OR REPLACE FUNCTION public.admin_remove_store(p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  DELETE FROM public.points_ledger          WHERE store_id = p_store_id;
  DELETE FROM public.store_memberships      WHERE store_id = p_store_id;
  DELETE FROM public.store_staff            WHERE store_id = p_store_id;
  DELETE FROM public.store_managers         WHERE store_id = p_store_id;
  DELETE FROM public.store_staff_applicants WHERE store_id = p_store_id;
  DELETE FROM public.store_reward_rules     WHERE store_id = p_store_id;
  DELETE FROM public.stores                 WHERE id        = p_store_id;
END $$;

-- ── Admin RPCs for reward rules ───────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_insert_reward_rule(
  p_store_id   uuid,
  p_label      text,
  p_points     int,
  p_kind       text,
  p_sort_order int
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_rule public.store_reward_rules;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  INSERT INTO public.store_reward_rules (store_id, label, points, kind, sort_order, is_active, is_pinned)
  VALUES (p_store_id, p_label, p_points, p_kind, p_sort_order, true, false)
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
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  DELETE FROM public.store_reward_rules WHERE id = p_id;
END $$;

CREATE OR REPLACE FUNCTION public.admin_update_reward_rule_order(p_id uuid, p_sort_order int)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  UPDATE public.store_reward_rules SET sort_order = p_sort_order WHERE id = p_id;
END $$;

-- ── Admin RPCs for managers and staff ────────────────────────────────────────

DROP FUNCTION IF EXISTS public.admin_assign_manager(uuid, uuid);
CREATE OR REPLACE FUNCTION public.admin_assign_manager(p_user_id uuid, p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  INSERT INTO public.store_managers (user_id, store_id) VALUES (p_user_id, p_store_id)
  ON CONFLICT DO NOTHING;
END $$;

CREATE OR REPLACE FUNCTION public.admin_assign_staff(p_user_id uuid, p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
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
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  DELETE FROM public.store_staff WHERE user_id = p_user_id AND store_id = p_store_id;
END $$;

CREATE OR REPLACE FUNCTION public.admin_remove_manager(p_user_id uuid, p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  DELETE FROM public.store_managers WHERE user_id = p_user_id AND store_id = p_store_id;
END $$;

CREATE OR REPLACE FUNCTION public.admin_approve_applicant(p_user_id uuid, p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  INSERT INTO public.store_staff (user_id, store_id) VALUES (p_user_id, p_store_id)
  ON CONFLICT DO NOTHING;
  DELETE FROM public.store_staff_applicants WHERE user_id = p_user_id AND store_id = p_store_id;
END $$;

CREATE OR REPLACE FUNCTION public.admin_reject_applicant(p_user_id uuid, p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  DELETE FROM public.store_staff_applicants WHERE user_id = p_user_id AND store_id = p_store_id;
END $$;

-- ── After running this script ─────────────────────────────────────────────────
-- Insert your user_id into the admins table:
--   INSERT INTO public.admins (user_id) VALUES ('your-auth-uid-here');
-- Find your user_id in Supabase Dashboard → Authentication → Users.
