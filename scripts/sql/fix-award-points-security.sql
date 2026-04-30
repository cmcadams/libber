-- Security fix: award_points RPC.
-- Run in the Supabase SQL Editor (Dashboard → SQL Editor).
-- Safe to re-run (CREATE OR REPLACE, same signature as current version).
--
-- Changes vs the version in add-bonus-cap.sql:
--   1. Redemptions (p_points < 0) now REQUIRE a p_rule_id.
--      A direct API call with no rule_id is rejected outright.
--   2. When p_rule_id is provided for a redemption, the rule is validated:
--      must belong to this store, be active, be kind='redeem', and its
--      stored cost must equal the absolute value of p_points.
--   3. After computing v_new_balance, a guard prevents it going below 0.
--      This closes the gap where a direct RPC call could drain a customer's
--      balance past zero even if the client-side check was bypassed.

CREATE OR REPLACE FUNCTION public.award_points(
  p_user_id  uuid,
  p_store_id uuid,
  p_points   integer,
  p_reason   text,
  p_rule_id  uuid DEFAULT NULL
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

  -- Serialize concurrent calls for the same (user, store) pair.
  -- Placed after auth so unauthorized requests are rejected before acquiring any lock.
  -- Transaction-scoped: PostgreSQL releases it automatically on commit or rollback.
  PERFORM pg_advisory_xact_lock(hashtext(p_user_id::text), hashtext(p_store_id::text));

  IF p_points = 0 THEN RAISE EXCEPTION 'points cannot be zero'; END IF;

  IF p_points > 0 THEN
    IF p_rule_id IS NOT NULL THEN
      -- Rule-based award: must match an active award rule for this store
      IF NOT EXISTS (
        SELECT 1 FROM public.store_reward_rules
        WHERE id       = p_rule_id
          AND store_id = p_store_id
          AND is_active = true
          AND kind     = 'award'
          AND points   = p_points
      ) THEN
        RAISE EXCEPTION 'invalid rule for this award';
      END IF;
    ELSE
      -- Free-form bonus: apply the store cap
      SELECT max_bonus_points INTO v_max_bonus FROM public.stores WHERE id = p_store_id;
      IF v_max_bonus IS NOT NULL AND p_points > v_max_bonus THEN
        RAISE EXCEPTION 'exceeds bonus cap of % points for this store', v_max_bonus;
      END IF;
    END IF;

  ELSE
    -- Negative points = redemption.
    -- Free-form deductions belong in adjust_points (explicitly audited, no cap bypass).
    -- award_points redemptions must always reference a configured rule.

    IF p_rule_id IS NULL THEN
      RAISE EXCEPTION 'redemptions must reference a reward rule (p_rule_id required)';
    END IF;

    -- rule.points stores the positive cost; p_points arrives as negative
    IF NOT EXISTS (
      SELECT 1 FROM public.store_reward_rules
      WHERE id       = p_rule_id
        AND store_id = p_store_id
        AND is_active = true
        AND kind     = 'redeem'
        AND points   = -p_points
    ) THEN
      RAISE EXCEPTION 'invalid rule for this redemption';
    END IF;

  END IF;

  -- Fetch the current running balance
  SELECT running_balance INTO v_current_balance
  FROM public.points_ledger
  WHERE user_id  = p_user_id
    AND store_id = p_store_id
  ORDER BY created_at DESC
  LIMIT 1;

  v_current_balance := coalesce(v_current_balance, 0);
  v_new_balance     := v_current_balance + p_points;

  -- Hard floor: balance cannot go negative under any circumstance
  IF v_new_balance < 0 THEN
    RAISE EXCEPTION 'insufficient points: balance is % but operation requires %',
      v_current_balance, -p_points;
  END IF;

  INSERT INTO public.points_ledger (user_id, store_id, points, reason, created_by, running_balance)
  VALUES (p_user_id, p_store_id, p_points, p_reason, v_staff_id, v_new_balance);

  RETURN v_new_balance;
END;
$$;
