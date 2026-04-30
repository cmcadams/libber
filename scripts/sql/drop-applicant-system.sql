-- Final removal of the apply-to-store system from the database.
-- Run in the Supabase SQL Editor (Dashboard → SQL Editor).
-- Safe to re-run — all statements use IF EXISTS.
--
-- Prerequisites confirmed before this migration was written:
--   - No frontend or admin code calls any of these RPCs or queries these tables.
--   - Maintenance scripts (delete-user, delete-store, delete-all-users, reset-all)
--     have been updated and no longer reference the applicant tables.
--   - Active RPCs (approve_staff_applicant, admin_assign_manager, admin_remove_store)
--     have been redeployed without applicant-table DELETE statements.

-- ── Step 1: Drop dead RPCs ────────────────────────────────────────────────────
-- None of these are called by any frontend, admin tool, or other RPC.

DROP FUNCTION IF EXISTS public.apply_for_staff(uuid);
DROP FUNCTION IF EXISTS public.apply_for_manager(uuid);
DROP FUNCTION IF EXISTS public.reject_staff_applicant(uuid, uuid);
DROP FUNCTION IF EXISTS public.admin_approve_applicant(uuid, uuid);
DROP FUNCTION IF EXISTS public.admin_reject_applicant(uuid, uuid);
DROP FUNCTION IF EXISTS public.admin_reject_manager_applicant(uuid, uuid);

-- ── Step 2: Drop any views that depended on the applicant tables ──────────────
-- staff_applicant_directory was referenced in old frontend code (loadApplicants).
-- It is not defined in any tracked SQL file — likely created manually in the
-- Supabase dashboard. Drop it here if it exists.

DROP VIEW IF EXISTS public.staff_applicant_directory;
DROP VIEW IF EXISTS public.manager_applicant_directory;

-- ── Step 3: Drop the tables ───────────────────────────────────────────────────
-- Cascades automatically drop RLS policies attached to each table.
-- Foreign key references to auth.users and stores used ON DELETE CASCADE,
-- so no orphaned constraint exists on the parent tables.

DROP TABLE IF EXISTS public.store_staff_applicants;
DROP TABLE IF EXISTS public.store_manager_applicants;
