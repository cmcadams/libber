-- add-outlets.sql
-- Adds store_outlets table, outlet_id to points_ledger, and all related RPCs.
-- Safe to re-run — uses CREATE OR REPLACE and IF NOT EXISTS throughout.
-- Run in Supabase SQL Editor (Dashboard → SQL Editor).
-- Re-run fix-default-privileges.sql afterwards.

-- ── store_outlets table ───────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.store_outlets (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id   uuid        NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
  name       text        NOT NULL CHECK (char_length(trim(name)) > 0),
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.store_outlets ENABLE ROW LEVEL SECURITY;

-- Authenticated users can read outlets (needed by staff to populate the picker)
DROP POLICY IF EXISTS "outlets: authenticated read" ON public.store_outlets;
CREATE POLICY "outlets: authenticated read" ON public.store_outlets
  FOR SELECT USING (auth.role() = 'authenticated');

-- No direct writes from clients — all mutations go through RPCs
DROP POLICY IF EXISTS "outlets: no direct insert" ON public.store_outlets;
DROP POLICY IF EXISTS "outlets: no direct update" ON public.store_outlets;
DROP POLICY IF EXISTS "outlets: no direct delete" ON public.store_outlets;
CREATE POLICY "outlets: no direct insert" ON public.store_outlets AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY "outlets: no direct update" ON public.store_outlets AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY "outlets: no direct delete" ON public.store_outlets AS RESTRICTIVE FOR DELETE USING (false);

-- ── outlet_id on points_ledger ────────────────────────────────────────────────
-- Nullable — existing rows and stores with no outlets produce NULL here.
-- Balance calculation is unaffected; this column is purely for analytics.

ALTER TABLE public.points_ledger
  ADD COLUMN IF NOT EXISTS outlet_id uuid REFERENCES public.store_outlets(id) ON DELETE SET NULL;

-- ── Admin RPCs ────────────────────────────────────────────────────────────────

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
  IF NOT EXISTS (SELECT 1 FROM public.stores WHERE id = p_store_id) THEN
    RAISE EXCEPTION 'Store not found';
  END IF;
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
  v_outlet public.store_outlets;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  UPDATE public.store_outlets
  SET name = trim(p_name)
  WHERE id = p_outlet_id
  RETURNING * INTO v_outlet;
  IF v_outlet IS NULL THEN RAISE EXCEPTION 'Outlet not found'; END IF;
  RETURN row_to_json(v_outlet);
END $$;

CREATE OR REPLACE FUNCTION public.admin_delete_outlet(p_outlet_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  DELETE FROM public.store_outlets WHERE id = p_outlet_id;
END $$;

-- ── Staff-facing RPC ──────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.load_store_outlets(p_store_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.store_staff
    WHERE user_id = auth.uid() AND store_id = p_store_id
    UNION
    SELECT 1 FROM public.store_managers
    WHERE user_id = auth.uid() AND store_id = p_store_id
  ) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  RETURN (
    SELECT COALESCE(json_agg(
      json_build_object('id', id, 'name', name)
      ORDER BY name
    ), '[]'::json)
    FROM public.store_outlets
    WHERE store_id = p_store_id
  );
END $$;

-- ── Modify award_points to accept outlet_id ───────────────────────────────────
-- Drop the old 5-argument signature to avoid overload ambiguity.

DROP FUNCTION IF EXISTS public.award_points(uuid, uuid, integer, text, uuid);

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
  v_staff_id        uuid;
  v_max_bonus       integer;
  v_current_balance integer;
  v_new_balance     integer;
BEGIN
  v_staff_id := auth.uid();
  IF v_staff_id IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.store_staff
    WHERE user_id = v_staff_id AND store_id = p_store_id
    UNION
    SELECT 1 FROM public.store_managers
    WHERE user_id = v_staff_id AND store_id = p_store_id
  ) THEN
    RAISE EXCEPTION 'not authorized: not staff or manager for this store';
  END IF;

  IF p_points = 0 THEN RAISE EXCEPTION 'points cannot be zero'; END IF;

  IF p_points > 0 THEN
    IF p_rule_id IS NOT NULL THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.store_reward_rules
        WHERE id = p_rule_id
          AND store_id = p_store_id
          AND is_active = true
          AND kind = 'award'
          AND points = p_points
      ) THEN
        RAISE EXCEPTION 'invalid rule for this award';
      END IF;
    ELSE
      SELECT max_bonus_points INTO v_max_bonus FROM public.stores WHERE id = p_store_id;
      IF v_max_bonus IS NOT NULL AND p_points > v_max_bonus THEN
        RAISE EXCEPTION 'exceeds bonus cap of % points for this store', v_max_bonus;
      END IF;
    END IF;
  END IF;

  -- Validate outlet belongs to this store if provided
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

-- ── Modify adjust_points to accept outlet_id ──────────────────────────────────
-- Drop the old 4-argument signature to avoid overload ambiguity.

DROP FUNCTION IF EXISTS public.adjust_points(uuid, uuid, integer, text);

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
  v_staff_id        uuid;
  v_current_balance integer;
  v_new_balance     integer;
BEGIN
  v_staff_id := auth.uid();
  IF v_staff_id IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_points = 0 THEN RAISE EXCEPTION 'points cannot be zero'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.store_staff   WHERE user_id = v_staff_id AND store_id = p_store_id
    UNION
    SELECT 1 FROM public.store_managers WHERE user_id = v_staff_id AND store_id = p_store_id
  ) THEN
    RAISE EXCEPTION 'not authorized: not staff or manager for this store';
  END IF;

  -- Validate outlet belongs to this store if provided
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
-- Explicit grants for new RPCs. fix-default-privileges.sql covers all functions
-- but re-granting here makes this script self-contained.

GRANT EXECUTE ON FUNCTION public.admin_create_outlet(uuid, text)     TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_outlet(uuid, text)     TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_outlet(uuid)           TO authenticated;
GRANT EXECUTE ON FUNCTION public.load_store_outlets(uuid)            TO authenticated;
GRANT EXECUTE ON FUNCTION public.award_points(uuid, uuid, integer, text, uuid, uuid)  TO authenticated;
GRANT EXECUTE ON FUNCTION public.adjust_points(uuid, uuid, integer, text, uuid)       TO authenticated;

-- ── Re-run fix-default-privileges.sql after this script ──────────────────────
