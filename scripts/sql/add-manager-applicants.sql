-- Manager application flow.
-- Run in the Supabase SQL Editor (Dashboard → SQL Editor).
-- Safe to re-run — all statements are idempotent.

-- ── store_manager_applicants table ───────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.store_manager_applicants (
  user_id    uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  store_id   uuid NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, store_id)
);

ALTER TABLE public.store_manager_applicants ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "manager_applicants: select" ON public.store_manager_applicants;
DROP POLICY IF EXISTS "manager_applicants: no direct insert" ON public.store_manager_applicants;
DROP POLICY IF EXISTS "manager_applicants: no direct delete" ON public.store_manager_applicants;

CREATE POLICY "manager_applicants: select" ON public.store_manager_applicants
  FOR SELECT USING (true);
CREATE POLICY "manager_applicants: no direct insert" ON public.store_manager_applicants
  AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY "manager_applicants: no direct delete" ON public.store_manager_applicants
  AS RESTRICTIVE FOR DELETE USING (false);

-- ── apply_for_manager ─────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.apply_for_manager(p_store_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_store_id IS NULL THEN RAISE EXCEPTION 'missing store_id'; END IF;

  INSERT INTO public.store_manager_applicants (user_id, store_id)
  VALUES (v_user_id, p_store_id)
  ON CONFLICT (user_id, store_id) DO NOTHING;

  RETURN json_build_object('success', true, 'user_id', v_user_id, 'store_id', p_store_id);
END $$;

-- ── admin_reject_manager_applicant ────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_reject_manager_applicant(p_user_id uuid, p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  DELETE FROM public.store_manager_applicants WHERE user_id = p_user_id AND store_id = p_store_id;
END $$;

-- ── Update admin_assign_manager to clean up applicant record ──────────────────

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
  DELETE FROM public.store_manager_applicants WHERE user_id = p_user_id AND store_id = p_store_id;
END $$;

-- ── Update admin_remove_store to clean up manager applicants ──────────────────

CREATE OR REPLACE FUNCTION public.admin_remove_store(p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  DELETE FROM public.points_ledger             WHERE store_id = p_store_id;
  DELETE FROM public.store_memberships         WHERE store_id = p_store_id;
  DELETE FROM public.store_staff               WHERE store_id = p_store_id;
  DELETE FROM public.store_managers            WHERE store_id = p_store_id;
  DELETE FROM public.store_staff_applicants    WHERE store_id = p_store_id;
  DELETE FROM public.store_manager_applicants  WHERE store_id = p_store_id;
  DELETE FROM public.store_reward_rules        WHERE store_id = p_store_id;
  DELETE FROM public.stores                    WHERE id        = p_store_id;
END $$;
