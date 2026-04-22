-- Admin RPCs and security hardening.
-- Safe to re-run — all statements are idempotent.
-- Run in the Supabase SQL Editor (Dashboard → SQL Editor).

-- ── Admins table ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.admins (
  user_id    uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at timestamptz DEFAULT now()
);

ALTER TABLE public.admins ENABLE ROW LEVEL SECURITY;

-- Only service role can read or modify the admins table directly.
-- Use the SQL editor to INSERT your own user_id after running this script.
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

-- ── Ensure RLS is enabled on all affected tables ─────────────────────────────

ALTER TABLE public.stores                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_reward_rules     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_managers         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_staff            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_memberships      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_staff_applicants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.points_ledger          ENABLE ROW LEVEL SECURITY;

-- ── RLS: block direct writes to stores ───────────────────────────────────────

DROP POLICY IF EXISTS "stores: no direct insert" ON public.stores;
DROP POLICY IF EXISTS "stores: no direct update" ON public.stores;
DROP POLICY IF EXISTS "stores: no direct delete" ON public.stores;

CREATE POLICY "stores: no direct insert" ON public.stores AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY "stores: no direct update" ON public.stores AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY "stores: no direct delete" ON public.stores AS RESTRICTIVE FOR DELETE USING (false);

-- ── RLS: block direct writes to store_reward_rules ───────────────────────────

DROP POLICY IF EXISTS "rules: no direct insert" ON public.store_reward_rules;
DROP POLICY IF EXISTS "rules: no direct update" ON public.store_reward_rules;
DROP POLICY IF EXISTS "rules: no direct delete" ON public.store_reward_rules;

CREATE POLICY "rules: no direct insert" ON public.store_reward_rules AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY "rules: no direct update" ON public.store_reward_rules AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY "rules: no direct delete" ON public.store_reward_rules AS RESTRICTIVE FOR DELETE USING (false);

-- ── RLS: block direct writes to store_managers ───────────────────────────────

DROP POLICY IF EXISTS "managers: no direct insert" ON public.store_managers;
DROP POLICY IF EXISTS "managers: no direct delete" ON public.store_managers;

CREATE POLICY "managers: no direct insert" ON public.store_managers AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY "managers: no direct delete" ON public.store_managers AS RESTRICTIVE FOR DELETE USING (false);

-- ── RLS: block direct writes to store_staff ──────────────────────────────────

DROP POLICY IF EXISTS "staff: no direct insert" ON public.store_staff;
DROP POLICY IF EXISTS "staff: no direct delete" ON public.store_staff;

CREATE POLICY "staff: no direct insert" ON public.store_staff AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY "staff: no direct delete" ON public.store_staff AS RESTRICTIVE FOR DELETE USING (false);

-- ── RLS: block direct writes to store_memberships ────────────────────────────

DROP POLICY IF EXISTS "memberships: no direct insert" ON public.store_memberships;
DROP POLICY IF EXISTS "memberships: no direct delete" ON public.store_memberships;

CREATE POLICY "memberships: no direct insert" ON public.store_memberships AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY "memberships: no direct delete" ON public.store_memberships AS RESTRICTIVE FOR DELETE USING (false);

-- ── RLS: block direct writes to store_staff_applicants ───────────────────────

DROP POLICY IF EXISTS "applicants: no direct insert" ON public.store_staff_applicants;
DROP POLICY IF EXISTS "applicants: no direct delete" ON public.store_staff_applicants;

CREATE POLICY "applicants: no direct insert" ON public.store_staff_applicants AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY "applicants: no direct delete" ON public.store_staff_applicants AS RESTRICTIVE FOR DELETE USING (false);

-- ── RLS: make points_ledger immutable ────────────────────────────────────────

DROP POLICY IF EXISTS "ledger: no direct delete" ON public.points_ledger;
DROP POLICY IF EXISTS "ledger: no direct update" ON public.points_ledger;

CREATE POLICY "ledger: no direct delete" ON public.points_ledger AS RESTRICTIVE FOR DELETE USING (false);
CREATE POLICY "ledger: no direct update" ON public.points_ledger AS RESTRICTIVE FOR UPDATE USING (false);

-- ── Store RPCs ────────────────────────────────────────────────────────────────

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

-- ── Reward rule RPCs ──────────────────────────────────────────────────────────

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

-- ── Staff / manager RPCs ──────────────────────────────────────────────────────

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

-- ── Existing RPCs: ensure SECURITY DEFINER so they bypass RLS blocks ─────────
-- These redefine the existing functions with SECURITY DEFINER + search_path.
-- Auth checks are preserved — only the execution context changes.

CREATE OR REPLACE FUNCTION public.join_store(p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  INSERT INTO public.store_memberships (user_id, store_id)
  VALUES (auth.uid(), p_store_id)
  ON CONFLICT DO NOTHING;
END $$;

CREATE OR REPLACE FUNCTION public.apply_for_staff(p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  INSERT INTO public.store_staff_applicants (user_id, store_id)
  VALUES (auth.uid(), p_store_id)
  ON CONFLICT DO NOTHING;
END $$;

CREATE OR REPLACE FUNCTION public.approve_staff_applicant(p_user_id uuid, p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.store_managers
    WHERE user_id = auth.uid() AND store_id = p_store_id
  ) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  INSERT INTO public.store_staff (user_id, store_id)
  VALUES (p_user_id, p_store_id)
  ON CONFLICT DO NOTHING;
  DELETE FROM public.store_staff_applicants
  WHERE user_id = p_user_id AND store_id = p_store_id;
END $$;

CREATE OR REPLACE FUNCTION public.demote_store_staff(p_user_id uuid, p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.store_managers
    WHERE user_id = auth.uid() AND store_id = p_store_id
  ) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  DELETE FROM public.store_staff
  WHERE user_id = p_user_id AND store_id = p_store_id;
END $$;

-- ── After running this script ─────────────────────────────────────────────────
-- Insert your user_id into the admins table via the SQL editor:
--   INSERT INTO public.admins (user_id) VALUES ('your-auth-uid-here');
-- Find your user_id in Authentication → Users in the Supabase dashboard.
