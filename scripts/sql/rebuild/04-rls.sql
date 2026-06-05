-- 04-rls.sql
--
-- All Row Level Security policies for every table.
-- Pattern: permissive SELECT policies for reads; RESTRICTIVE false policies
-- for every write operation. RESTRICTIVE policies block writes even if a
-- future accidental GRANT widens table privileges — defence-in-depth.
--
-- Run order: AFTER 03-auth-helpers.sql (profiles and store_staff admin
-- policies call is_admin() at evaluation time; it must already exist).
--
-- All writes go through SECURITY DEFINER RPCs which bypass RLS entirely.
-- The RESTRICTIVE write blocks here are a safety net, not the primary guard.
--
-- Audit fixes applied:
--   IMPORTANT Added RESTRICTIVE UPDATE policies to store_managers and
--             store_staff — the original set only blocked INSERT and DELETE;
--             UPDATE was unguarded, inconsistent with every other table

-- ── admins ────────────────────────────────────────────────────────────────────
-- Readable and writable by service role only.
-- Authenticated clients should never be able to inspect the admins table.
-- RESTRICTIVE write guards are belt-and-suspenders: even if a future grant
-- accidentally widens privileges, no authenticated user can ever write here.

DROP POLICY IF EXISTS "admins: service role only"  ON public.admins;
DROP POLICY IF EXISTS "admins: no direct insert"   ON public.admins;
DROP POLICY IF EXISTS "admins: no direct update"   ON public.admins;
DROP POLICY IF EXISTS "admins: no direct delete"   ON public.admins;

CREATE POLICY "admins: service role only" ON public.admins
  USING (auth.role() = 'service_role');

CREATE POLICY "admins: no direct insert" ON public.admins AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY "admins: no direct update" ON public.admins AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY "admins: no direct delete" ON public.admins AS RESTRICTIVE FOR DELETE USING (false);

-- ── profiles ──────────────────────────────────────────────────────────────────
-- Each user reads only their own row.
-- Admins read all rows (needed for admin_user_directory view).
-- SECURITY DEFINER RPCs (load_store_members, load_store_staff_profiles,
-- load_customer_home) bypass RLS and can read any profile row.

DROP POLICY IF EXISTS "profiles: allow select"    ON public.profiles;
DROP POLICY IF EXISTS "profiles: select own"      ON public.profiles;
DROP POLICY IF EXISTS "profiles: select as admin" ON public.profiles;

CREATE POLICY "profiles: select own" ON public.profiles
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "profiles: select as admin" ON public.profiles
  FOR SELECT USING (public.is_admin());

-- ── stores ────────────────────────────────────────────────────────────────────
-- SELECT is open to all authenticated users (customer app needs the store list).
-- All mutations go through admin RPCs.

DROP POLICY IF EXISTS "stores: allow select"     ON public.stores;
DROP POLICY IF EXISTS "stores: no direct insert" ON public.stores;
DROP POLICY IF EXISTS "stores: no direct update" ON public.stores;
DROP POLICY IF EXISTS "stores: no direct delete" ON public.stores;

CREATE POLICY "stores: allow select"     ON public.stores FOR SELECT USING (true);
CREATE POLICY "stores: no direct insert" ON public.stores AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY "stores: no direct update" ON public.stores AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY "stores: no direct delete" ON public.stores AS RESTRICTIVE FOR DELETE USING (false);

-- ── store_memberships ─────────────────────────────────────────────────────────
-- Users see only their own active memberships.
-- All mutations (join, unjoin, soft-remove) go through SECURITY DEFINER RPCs.

DROP POLICY IF EXISTS "memberships: select own"       ON public.store_memberships;
DROP POLICY IF EXISTS "memberships: no direct insert" ON public.store_memberships;
DROP POLICY IF EXISTS "memberships: no direct update" ON public.store_memberships;
DROP POLICY IF EXISTS "memberships: no direct delete" ON public.store_memberships;

CREATE POLICY "memberships: select own" ON public.store_memberships
  FOR SELECT USING (user_id = auth.uid() AND is_active = true);

CREATE POLICY "memberships: no direct insert" ON public.store_memberships AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY "memberships: no direct update" ON public.store_memberships AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY "memberships: no direct delete" ON public.store_memberships AS RESTRICTIVE FOR DELETE USING (false);

-- ── store_managers ────────────────────────────────────────────────────────────
-- Managers see their own rows; admins see all.
-- Full INSERT + UPDATE + DELETE block — these rows are managed by admin RPCs only.

DROP POLICY IF EXISTS "managers: allow select"     ON public.store_managers;
DROP POLICY IF EXISTS "managers: no direct insert" ON public.store_managers;
DROP POLICY IF EXISTS "managers: no direct update" ON public.store_managers;
DROP POLICY IF EXISTS "managers: no direct delete" ON public.store_managers;

CREATE POLICY "managers: allow select" ON public.store_managers
  FOR SELECT USING (user_id = auth.uid() OR public.is_admin());

CREATE POLICY "managers: no direct insert" ON public.store_managers AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY "managers: no direct update" ON public.store_managers AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY "managers: no direct delete" ON public.store_managers AS RESTRICTIVE FOR DELETE USING (false);

-- ── store_staff ───────────────────────────────────────────────────────────────
-- Staff see their own rows; managers see staff at their stores; admins see all.
-- Three separate permissive policies — any one passing is sufficient for SELECT.
-- Full INSERT + UPDATE + DELETE block — these rows are managed by admin RPCs only.

DROP POLICY IF EXISTS "staff: allow select"      ON public.store_staff;
DROP POLICY IF EXISTS "staff: select self"       ON public.store_staff;
DROP POLICY IF EXISTS "staff: select as manager" ON public.store_staff;
DROP POLICY IF EXISTS "staff: select as admin"   ON public.store_staff;
DROP POLICY IF EXISTS "staff: no direct insert"  ON public.store_staff;
DROP POLICY IF EXISTS "staff: no direct update"  ON public.store_staff;
DROP POLICY IF EXISTS "staff: no direct delete"  ON public.store_staff;

CREATE POLICY "staff: select self" ON public.store_staff
  FOR SELECT USING (user_id = auth.uid());

CREATE POLICY "staff: select as manager" ON public.store_staff
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.store_managers
      WHERE store_id = store_staff.store_id AND user_id = auth.uid()
    )
  );

CREATE POLICY "staff: select as admin" ON public.store_staff
  FOR SELECT USING (public.is_admin());

CREATE POLICY "staff: no direct insert" ON public.store_staff AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY "staff: no direct update" ON public.store_staff AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY "staff: no direct delete" ON public.store_staff AS RESTRICTIVE FOR DELETE USING (false);

-- ── store_reward_rules ────────────────────────────────────────────────────────
-- Rules are non-sensitive; any authenticated user can read them.

DROP POLICY IF EXISTS "rules: allow select"     ON public.store_reward_rules;
DROP POLICY IF EXISTS "rules: no direct insert" ON public.store_reward_rules;
DROP POLICY IF EXISTS "rules: no direct update" ON public.store_reward_rules;
DROP POLICY IF EXISTS "rules: no direct delete" ON public.store_reward_rules;

CREATE POLICY "rules: allow select"     ON public.store_reward_rules FOR SELECT USING (true);
CREATE POLICY "rules: no direct insert" ON public.store_reward_rules AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY "rules: no direct update" ON public.store_reward_rules AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY "rules: no direct delete" ON public.store_reward_rules AS RESTRICTIVE FOR DELETE USING (false);

-- ── store_outlets ─────────────────────────────────────────────────────────────
-- Readable by authenticated users (staff need the outlet picker).
-- All mutations go through admin RPCs.

DROP POLICY IF EXISTS "outlets: authenticated read" ON public.store_outlets;
DROP POLICY IF EXISTS "outlets: no direct insert"   ON public.store_outlets;
DROP POLICY IF EXISTS "outlets: no direct update"   ON public.store_outlets;
DROP POLICY IF EXISTS "outlets: no direct delete"   ON public.store_outlets;

CREATE POLICY "outlets: authenticated read" ON public.store_outlets
  FOR SELECT USING (auth.role() = 'authenticated');

CREATE POLICY "outlets: no direct insert" ON public.store_outlets AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY "outlets: no direct update" ON public.store_outlets AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY "outlets: no direct delete" ON public.store_outlets AS RESTRICTIVE FOR DELETE USING (false);

-- ── points_ledger ─────────────────────────────────────────────────────────────
-- Users see only their own rows. SELECT is retained for the Realtime subscription
-- (Supabase Realtime evaluates RLS per-event to filter INSERT notifications).
-- Append-only: RESTRICTIVE UPDATE and DELETE make direct mutation structurally
-- impossible even if table privileges are ever widened by mistake.

DROP POLICY IF EXISTS "ledger: select own"       ON public.points_ledger;
DROP POLICY IF EXISTS "ledger: no direct insert" ON public.points_ledger;
DROP POLICY IF EXISTS "ledger: no direct update" ON public.points_ledger;
DROP POLICY IF EXISTS "ledger: no direct delete" ON public.points_ledger;

CREATE POLICY "ledger: select own" ON public.points_ledger
  FOR SELECT USING (user_id = auth.uid());

CREATE POLICY "ledger: no direct insert" ON public.points_ledger AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY "ledger: no direct update" ON public.points_ledger AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY "ledger: no direct delete" ON public.points_ledger AS RESTRICTIVE FOR DELETE USING (false);

-- ── ab_variants ───────────────────────────────────────────────────────────────
-- Readable by all authenticated users (variant data is non-sensitive).
-- Written only via SQL editor / seed scripts, not via client RPCs.

DROP POLICY IF EXISTS "ab_variants: allow select"     ON public.ab_variants;
DROP POLICY IF EXISTS "ab_variants: no direct insert" ON public.ab_variants;
DROP POLICY IF EXISTS "ab_variants: no direct update" ON public.ab_variants;
DROP POLICY IF EXISTS "ab_variants: no direct delete" ON public.ab_variants;

CREATE POLICY "ab_variants: allow select"     ON public.ab_variants FOR SELECT USING (true);
CREATE POLICY "ab_variants: no direct insert" ON public.ab_variants AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY "ab_variants: no direct update" ON public.ab_variants AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY "ab_variants: no direct delete" ON public.ab_variants AS RESTRICTIVE FOR DELETE USING (false);

-- ── Storage: store-logos bucket ───────────────────────────────────────────────

DROP POLICY IF EXISTS "store logos are publicly readable" ON storage.objects;
DROP POLICY IF EXISTS "admins can upload logos"           ON storage.objects;
DROP POLICY IF EXISTS "admins can update logos"           ON storage.objects;

-- Public read — logos are served directly from the CDN.
CREATE POLICY "store logos are publicly readable"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'store-logos');

-- Only admins may upload or overwrite logos.
CREATE POLICY "admins can upload logos"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (bucket_id = 'store-logos' AND public.is_admin());

CREATE POLICY "admins can update logos"
  ON storage.objects FOR UPDATE
  TO authenticated
  USING (bucket_id = 'store-logos' AND public.is_admin());
