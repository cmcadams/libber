-- Bonus cap: per-store limit on positive point awards.
-- Safe to re-run — ALTER TABLE uses IF NOT EXISTS, functions use CREATE OR REPLACE.
-- Run in the Supabase SQL Editor (Dashboard → SQL Editor).

-- ── Add column ────────────────────────────────────────────────────────────────

ALTER TABLE public.stores ADD COLUMN IF NOT EXISTS max_bonus_points integer;

-- ── admin_set_bonus_cap ───────────────────────────────────────────────────────
-- Pass NULL as p_max_bonus_points to remove the cap.

CREATE OR REPLACE FUNCTION public.admin_set_bonus_cap(
  p_store_id         uuid,
  p_max_bonus_points integer  -- NULL = no cap
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;

  IF NOT EXISTS (SELECT 1 FROM public.admins WHERE user_id = auth.uid()) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  IF p_max_bonus_points IS NOT NULL AND p_max_bonus_points < 1 THEN
    RAISE EXCEPTION 'bonus cap must be at least 1';
  END IF;

  UPDATE public.stores SET max_bonus_points = p_max_bonus_points WHERE id = p_store_id;
END $$;

-- ── award_points (updated with cap check) ─────────────────────────────────────

CREATE OR REPLACE FUNCTION public.award_points(
  p_user_id  uuid,
  p_store_id uuid,
  p_points   integer,
  p_reason   text
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
    SELECT max_bonus_points INTO v_max_bonus FROM public.stores WHERE id = p_store_id;
    IF v_max_bonus IS NOT NULL AND p_points > v_max_bonus THEN
      RAISE EXCEPTION 'exceeds bonus cap of % points for this store', v_max_bonus;
    END IF;
  END IF;

  SELECT running_balance INTO v_current_balance
  FROM public.points_ledger
  WHERE user_id = p_user_id AND store_id = p_store_id
  ORDER BY created_at DESC
  LIMIT 1;

  v_current_balance := coalesce(v_current_balance, 0);
  v_new_balance     := v_current_balance + p_points;

  INSERT INTO public.points_ledger (user_id, store_id, points, reason, created_by, running_balance)
  VALUES (p_user_id, p_store_id, p_points, p_reason, v_staff_id, v_new_balance);

  RETURN v_new_balance;
END $$;
