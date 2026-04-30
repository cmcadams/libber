-- Create admin_user_directory as a tracked, security-correct view.
-- Run in the Supabase SQL Editor (Dashboard → SQL Editor).
-- Safe to re-run (DROP IF EXISTS before CREATE, policy drops are idempotent).
--
-- Background: admin_user_directory was previously created manually in the
-- Supabase dashboard with no tracked migration. Its security mode was unknown.
-- A SECURITY DEFINER view (PostgreSQL default before PG15) would bypass the
-- "profiles: select own" RLS policy and expose all user IDs to any caller.
--
-- This migration:
--   1. Adds a "profiles: select as admin" RLS policy so is_admin() users can
--      read all profile rows through the hardened profiles table.
--   2. Recreates the view with security_invoker = true so the caller's RLS
--      context applies — non-admins see only their own row; admins see all.
--   3. Revokes anon access on the view (consistent with harden-rls-and-grants).

-- ── 1. Allow admins to read all profiles ─────────────────────────────────────
-- The existing "profiles: select own" policy (from harden-rls-and-grants.sql)
-- restricts non-admins to their own row. This companion policy extends read
-- access to users where is_admin() is true.

DROP POLICY IF EXISTS "profiles: select as admin" ON public.profiles;
CREATE POLICY "profiles: select as admin" ON public.profiles
  FOR SELECT USING (public.is_admin());

-- ── 2. Recreate the view with security_invoker = true ────────────────────────
-- security_invoker = true means the view executes as the calling user, not the
-- view owner. PostgreSQL enforces RLS on the underlying profiles table using
-- the caller's identity, so the policies above determine what each caller sees:
--   - admin     → "profiles: select as admin" fires → all rows visible
--   - non-admin → only "profiles: select own" fires → own row only

DROP VIEW IF EXISTS public.admin_user_directory;
CREATE VIEW public.admin_user_directory
  WITH (security_invoker = true)
AS
  SELECT user_id, public_id
  FROM   public.profiles
  ORDER  BY public_id ASC NULLS LAST;

-- ── 3. Tighten grants on the view ────────────────────────────────────────────
-- PostgreSQL grants SELECT on a view to PUBLIC by default in some versions.
-- Revoke that, then grant explicitly only to authenticated — consistent with
-- the function-grant hardening in harden-rls-and-grants.sql.

REVOKE ALL    ON public.admin_user_directory FROM anon, PUBLIC;
GRANT  SELECT ON public.admin_user_directory TO authenticated;
