-- Admin RPCs and security hardening.
-- Run once in the Supabase SQL Editor (Dashboard → SQL Editor).
-- Creates the admins table, all admin RPCs, and RLS policies blocking direct writes.

-- ── Admins table ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS admins (
  user_id    uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at timestamptz DEFAULT now()
);

ALTER TABLE admins ENABLE ROW LEVEL SECURITY;

-- Only service role can read or modify the admins table directly.
-- Use the SQL editor to INSERT your own user_id after running this script.
DROP POLICY IF EXISTS "admins: service role only" ON admins;
CREATE POLICY "admins: service role only" ON admins
  USING (auth.role() = 'service_role');

-- ── is_admin() helper ─────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION is_admin()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT EXISTS (SELECT 1 FROM admins WHERE user_id = auth.uid())
$$;

-- ── RLS: block direct writes to stores ───────────────────────────────────────

DROP POLICY IF EXISTS "stores: no direct insert" ON stores;
DROP POLICY IF EXISTS "stores: no direct update" ON stores;
DROP POLICY IF EXISTS "stores: no direct delete" ON stores;

CREATE POLICY "stores: no direct insert" ON stores FOR INSERT WITH CHECK (false);
CREATE POLICY "stores: no direct update" ON stores FOR UPDATE USING (false);
CREATE POLICY "stores: no direct delete" ON stores FOR DELETE USING (false);

-- ── RLS: block direct writes to store_reward_rules ───────────────────────────

DROP POLICY IF EXISTS "rules: no direct insert" ON store_reward_rules;
DROP POLICY IF EXISTS "rules: no direct update" ON store_reward_rules;
DROP POLICY IF EXISTS "rules: no direct delete" ON store_reward_rules;

CREATE POLICY "rules: no direct insert" ON store_reward_rules FOR INSERT WITH CHECK (false);
CREATE POLICY "rules: no direct update" ON store_reward_rules FOR UPDATE USING (false);
CREATE POLICY "rules: no direct delete" ON store_reward_rules FOR DELETE USING (false);

-- ── RLS: block direct writes to store_managers ───────────────────────────────

DROP POLICY IF EXISTS "managers: no direct insert" ON store_managers;
DROP POLICY IF EXISTS "managers: no direct delete" ON store_managers;

CREATE POLICY "managers: no direct insert" ON store_managers FOR INSERT WITH CHECK (false);
CREATE POLICY "managers: no direct delete" ON store_managers FOR DELETE USING (false);

-- ── RLS: block direct writes to store_staff ──────────────────────────────────

DROP POLICY IF EXISTS "staff: no direct insert" ON store_staff;
DROP POLICY IF EXISTS "staff: no direct delete" ON store_staff;

CREATE POLICY "staff: no direct insert" ON store_staff FOR INSERT WITH CHECK (false);
CREATE POLICY "staff: no direct delete" ON store_staff FOR DELETE USING (false);

-- ── RLS: block direct writes to store_memberships ────────────────────────────

DROP POLICY IF EXISTS "memberships: no direct insert" ON store_memberships;
DROP POLICY IF EXISTS "memberships: no direct delete" ON store_memberships;

CREATE POLICY "memberships: no direct insert" ON store_memberships FOR INSERT WITH CHECK (false);
CREATE POLICY "memberships: no direct delete" ON store_memberships FOR DELETE USING (false);

-- ── RLS: block direct writes to store_staff_applicants ───────────────────────

DROP POLICY IF EXISTS "applicants: no direct insert" ON store_staff_applicants;
DROP POLICY IF EXISTS "applicants: no direct delete" ON store_staff_applicants;

CREATE POLICY "applicants: no direct insert" ON store_staff_applicants FOR INSERT WITH CHECK (false);
CREATE POLICY "applicants: no direct delete" ON store_staff_applicants FOR DELETE USING (false);

-- ── Store RPCs ────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION admin_create_store(p_name text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_store stores;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  INSERT INTO stores (name) VALUES (trim(p_name)) RETURNING * INTO v_store;
  RETURN row_to_json(v_store);
END $$;

CREATE OR REPLACE FUNCTION admin_update_store(p_store_id uuid, p_name text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_store stores;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  UPDATE stores SET name = trim(p_name) WHERE id = p_store_id RETURNING * INTO v_store;
  RETURN row_to_json(v_store);
END $$;

CREATE OR REPLACE FUNCTION admin_remove_store(p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  DELETE FROM points_ledger          WHERE store_id = p_store_id;
  DELETE FROM store_memberships      WHERE store_id = p_store_id;
  DELETE FROM store_staff            WHERE store_id = p_store_id;
  DELETE FROM store_managers         WHERE store_id = p_store_id;
  DELETE FROM store_staff_applicants WHERE store_id = p_store_id;
  DELETE FROM store_reward_rules     WHERE store_id = p_store_id;
  DELETE FROM stores                 WHERE id        = p_store_id;
END $$;

-- ── Reward rule RPCs ──────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION admin_insert_reward_rule(
  p_store_id   uuid,
  p_label      text,
  p_points     int,
  p_kind       text,
  p_sort_order int
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_rule store_reward_rules;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  INSERT INTO store_reward_rules (store_id, label, points, kind, sort_order, is_active, is_pinned)
  VALUES (p_store_id, p_label, p_points, p_kind, p_sort_order, true, false)
  RETURNING * INTO v_rule;
  RETURN row_to_json(v_rule);
END $$;

CREATE OR REPLACE FUNCTION admin_delete_reward_rule(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  DELETE FROM store_reward_rules WHERE id = p_id;
END $$;

CREATE OR REPLACE FUNCTION admin_update_reward_rule_order(p_id uuid, p_sort_order int)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  UPDATE store_reward_rules SET sort_order = p_sort_order WHERE id = p_id;
END $$;

-- ── Staff / manager RPCs ──────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION admin_assign_staff(p_user_id uuid, p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  INSERT INTO store_staff (user_id, store_id) VALUES (p_user_id, p_store_id)
  ON CONFLICT DO NOTHING;
END $$;

CREATE OR REPLACE FUNCTION admin_remove_staff(p_user_id uuid, p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  DELETE FROM store_staff WHERE user_id = p_user_id AND store_id = p_store_id;
END $$;

CREATE OR REPLACE FUNCTION admin_remove_manager(p_user_id uuid, p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  DELETE FROM store_managers WHERE user_id = p_user_id AND store_id = p_store_id;
END $$;

CREATE OR REPLACE FUNCTION admin_approve_applicant(p_user_id uuid, p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  INSERT INTO store_staff (user_id, store_id) VALUES (p_user_id, p_store_id)
  ON CONFLICT DO NOTHING;
  DELETE FROM store_staff_applicants WHERE user_id = p_user_id AND store_id = p_store_id;
END $$;

CREATE OR REPLACE FUNCTION admin_reject_applicant(p_user_id uuid, p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  DELETE FROM store_staff_applicants WHERE user_id = p_user_id AND store_id = p_store_id;
END $$;

-- ── admin_assign_manager (replace existing service-role-only version) ─────────

CREATE OR REPLACE FUNCTION admin_assign_manager(p_user_id uuid, p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  INSERT INTO store_managers (user_id, store_id) VALUES (p_user_id, p_store_id)
  ON CONFLICT DO NOTHING;
END $$;

-- ── After running this script ─────────────────────────────────────────────────
-- Insert your user_id into the admins table via the SQL editor:
--   INSERT INTO admins (user_id) VALUES ('your-auth-uid-here');
-- Find your user_id in Authentication → Users in the Supabase dashboard.
