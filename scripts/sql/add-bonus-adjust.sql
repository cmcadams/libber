-- Bonus/Adjust: kind constraint update + adjust_points RPC.
-- Safe to re-run (CREATE OR REPLACE, constraint drop/re-add is idempotent).
-- Run in Supabase SQL Editor after add-bonus-cap.sql.

-- ── Extend kind constraint to allow bonus_reason and bonus_amount ─────────────

ALTER TABLE public.store_reward_rules DROP CONSTRAINT IF EXISTS store_reward_rules_kind_check;

ALTER TABLE public.store_reward_rules ADD CONSTRAINT store_reward_rules_kind_check
  CHECK (kind IN ('award', 'redeem', 'bonus_reason', 'bonus_amount'));

-- ── adjust_points RPC ─────────────────────────────────────────────────────────
--
-- adjust_points is for staff corrections — positive or negative — with no cap check.
-- Separate from award_points so the cap bypass is explicit and auditable.

CREATE OR REPLACE FUNCTION public.adjust_points(
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
