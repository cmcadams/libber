-- rename-account-linked.sql
--
-- Renames email_saved_at → account_linked_at and mark_email_saved →
-- mark_account_linked throughout the schema. The old name was misleading:
-- the flag is set for both OAuth and magic-link flows, not just email.
--
-- Safe to re-run. The DO block skips the column rename if it has already
-- been applied. Supersedes the load_customer_home definition in
-- add-load-customer-home-rpc.sql and add-ab-testing.sql.

-- 1. Rename column (idempotent)
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'profiles'
      AND column_name  = 'email_saved_at'
  ) THEN
    ALTER TABLE public.profiles RENAME COLUMN email_saved_at TO account_linked_at;
  END IF;
END $$;

-- 2. Drop old function and create replacement
DROP FUNCTION IF EXISTS public.mark_email_saved();

CREATE OR REPLACE FUNCTION public.mark_account_linked()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE public.profiles
  SET    account_linked_at = now()
  WHERE  user_id           = auth.uid()
    AND  account_linked_at IS NULL;
END;
$$;

GRANT EXECUTE ON FUNCTION public.mark_account_linked() TO authenticated;

-- 3. Update load_customer_home — uses new column, returns 'account_linked'
CREATE OR REPLACE FUNCTION public.load_customer_home(p_include_stores boolean DEFAULT true)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id        uuid;
  v_public_id      text;
  v_variant        text;
  v_account_linked boolean;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;

  SELECT public_id,
         save_prompt_variant,
         (account_linked_at IS NOT NULL)
  INTO   v_public_id, v_variant, v_account_linked
  FROM   public.profiles
  WHERE  user_id = v_user_id;

  RETURN json_build_object(
    'public_id',      v_public_id,
    'account_linked', COALESCE(v_account_linked, false),
    'save_prompt', (
      SELECT json_build_object(
        'variant',  v.variant,
        'text',     v.text,
        'position', v.position
      )
      FROM   public.ab_variants v
      WHERE  v.test_name = 'save_prompt'
      AND    v.variant   = v_variant
      AND    v.is_active = true
      LIMIT  1
    ),
    'memberships', (
      SELECT COALESCE(json_agg(m_data), '[]'::json)
      FROM (
        SELECT json_build_object(
          'store_id',   sm.store_id,
          'store_name', s.name,
          'balance', COALESCE((
            SELECT running_balance FROM public.points_ledger
            WHERE user_id = v_user_id AND store_id = sm.store_id
            ORDER BY created_at DESC LIMIT 1
          ), 0),
          'rules', (
            SELECT COALESCE(json_agg(json_build_object(
              'label',  rr.label,
              'points', rr.points,
              'kind',   rr.kind
            ) ORDER BY rr.sort_order), '[]'::json)
            FROM public.store_reward_rules rr
            WHERE rr.store_id = sm.store_id AND rr.is_active = true
          ),
          'history', (
            SELECT COALESCE(json_agg(json_build_object(
              'reason',     h.reason,
              'points',     h.points,
              'created_at', h.created_at
            ) ORDER BY h.created_at DESC), '[]'::json)
            FROM (
              SELECT reason, points, created_at
              FROM public.points_ledger
              WHERE user_id = v_user_id AND store_id = sm.store_id
              ORDER BY created_at DESC
              LIMIT 10
            ) h
          )
        ) AS m_data
        FROM public.store_memberships sm
        JOIN public.stores s ON s.id = sm.store_id
        WHERE sm.user_id = v_user_id
        ORDER BY s.name
      ) sub
    ),
    'stores', CASE WHEN p_include_stores THEN (
      SELECT COALESCE(
        json_agg(json_build_object('id', id, 'name', name) ORDER BY name),
        '[]'::json
      )
      FROM public.stores
    ) ELSE NULL END
  );
END $$;
