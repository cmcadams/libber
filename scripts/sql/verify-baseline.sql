-- verify-baseline.sql
--
-- Drift detection for the Libber baseline (migrations 00–15).
-- Run this against any database that claims to match the baseline.
--
-- HOW TO USE:
--   Run each section in the Supabase SQL Editor.
--   Every query is a CHECK: it returns rows only when something is WRONG.
--   A healthy baseline returns zero rows from every query.
--
-- SECTIONS:
--   1.  Tables present
--   2.  RLS enabled
--   3.  Required columns present
--   4.  Indexes present
--   5.  Trigger present
--   6.  Functions present (by name)
--   7.  Function signatures (exact arg types)
--   8.  SECURITY DEFINER on all functions
--   9.  search_path = '' on all functions
--  10.  No anon/PUBLIC function grants
--  11.  RLS policies present
--  12.  Views present
--  13.  Realtime publication
--  14.  Storage bucket
--  15.  ab_variants seed data
--
-- Safe to re-run at any time. Read-only queries throughout.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. REQUIRED TABLES
-- Returns rows for any table that is missing.
-- ─────────────────────────────────────────────────────────────────────────────

SELECT t.expected_table AS missing_table
FROM (VALUES
  ('profiles'),
  ('stores'),
  ('store_memberships'),
  ('store_staff'),
  ('store_managers'),
  ('store_reward_rules'),
  ('points_ledger'),
  ('admins'),
  ('store_outlets'),
  ('ab_variants')
) AS t(expected_table)
WHERE NOT EXISTS (
  SELECT 1 FROM pg_tables
  WHERE schemaname = 'public'
    AND tablename  = t.expected_table
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. RLS ENABLED
-- Returns rows for any table that has RLS disabled.
-- ─────────────────────────────────────────────────────────────────────────────

SELECT t.expected_table AS rls_disabled_on
FROM (VALUES
  ('profiles'),
  ('stores'),
  ('store_memberships'),
  ('store_staff'),
  ('store_managers'),
  ('store_reward_rules'),
  ('points_ledger'),
  ('admins'),
  ('store_outlets'),
  ('ab_variants')
) AS t(expected_table)
WHERE NOT EXISTS (
  SELECT 1 FROM pg_class c
  JOIN   pg_namespace n ON n.oid = c.relnamespace
  WHERE  n.nspname   = 'public'
    AND  c.relname   = t.expected_table
    AND  c.relrowsecurity = true
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. REQUIRED COLUMNS
-- Returns rows for any (table, column) pair that is missing.
-- ─────────────────────────────────────────────────────────────────────────────

SELECT t.tbl AS missing_from_table, t.col AS missing_column
FROM (VALUES
  -- profiles
  ('profiles',              'user_id'),
  ('profiles',              'public_id'),
  ('profiles',              'save_prompt_variant'),
  ('profiles',              'interaction_count'),
  ('profiles',              'one_time_prompt_shown_at'),
  ('profiles',              'prompt_dismissed_at'),
  ('profiles',              'account_linked_at'),
  -- stores
  ('stores',                'id'),
  ('stores',                'name'),
  ('stores',                'max_bonus_points'),
  ('stores',                'logo_path'),
  ('stores',                'logo_updated_at'),
  ('stores',                'is_active'),
  ('stores',                'deleted_at'),
  -- store_memberships
  ('store_memberships',     'user_id'),
  ('store_memberships',     'store_id'),
  ('store_memberships',     'is_active'),
  -- store_staff
  ('store_staff',           'user_id'),
  ('store_staff',           'store_id'),
  -- store_managers
  ('store_managers',        'user_id'),
  ('store_managers',        'store_id'),
  -- store_reward_rules
  ('store_reward_rules',    'id'),
  ('store_reward_rules',    'store_id'),
  ('store_reward_rules',    'label'),
  ('store_reward_rules',    'points'),
  ('store_reward_rules',    'kind'),
  ('store_reward_rules',    'sort_order'),
  ('store_reward_rules',    'is_active'),
  ('store_reward_rules',    'is_pinned'),
  -- points_ledger
  ('points_ledger',         'id'),
  ('points_ledger',         'user_id'),
  ('points_ledger',         'store_id'),
  ('points_ledger',         'points'),
  ('points_ledger',         'reason'),
  ('points_ledger',         'created_by'),
  ('points_ledger',         'running_balance'),
  ('points_ledger',         'outlet_id'),
  -- admins
  ('admins',                'user_id'),
  -- store_outlets
  ('store_outlets',         'id'),
  ('store_outlets',         'store_id'),
  ('store_outlets',         'name'),
  -- ab_variants
  ('ab_variants',           'id'),
  ('ab_variants',           'test_name'),
  ('ab_variants',           'variant'),
  ('ab_variants',           'text'),
  ('ab_variants',           'position'),
  ('ab_variants',           'is_active'),
  ('ab_variants',           'weight')
) AS t(tbl, col)
WHERE NOT EXISTS (
  SELECT 1 FROM information_schema.columns c
  WHERE  c.table_schema = 'public'
    AND  c.table_name   = t.tbl
    AND  c.column_name  = t.col
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. REQUIRED INDEXES
-- Returns rows for any index that is missing.
-- ─────────────────────────────────────────────────────────────────────────────

SELECT t.expected_index AS missing_index
FROM (VALUES
  ('admins_user_id_idx'),
  ('store_managers_user_store_idx'),
  ('store_staff_user_store_idx'),
  ('stores_is_active_idx'),
  ('store_memberships_store_active_idx'),
  ('active_membership_unique')
) AS t(expected_index)
WHERE NOT EXISTS (
  SELECT 1 FROM pg_indexes
  WHERE schemaname = 'public'
    AND indexname  = t.expected_index
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. REQUIRED TRIGGER
-- Returns a row if the profile-creation trigger is missing.
-- ─────────────────────────────────────────────────────────────────────────────

SELECT 'on_auth_user_created trigger missing' AS problem
WHERE NOT EXISTS (
  SELECT 1
  FROM   information_schema.triggers
  WHERE  event_object_schema = 'auth'
    AND  event_object_table  = 'users'
    AND  trigger_name        = 'on_auth_user_created'
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. REQUIRED FUNCTIONS (by name)
-- Returns rows for any function name that is completely absent.
-- ─────────────────────────────────────────────────────────────────────────────

SELECT t.fn AS missing_function
FROM (VALUES
  ('is_admin'),
  ('get_store_role'),
  ('assert_store_access'),
  ('assert_store_manager'),
  ('assert_store_active'),
  ('assert_active_membership'),
  ('create_profile'),
  ('admin_create_store'),
  ('admin_update_store'),
  ('admin_remove_store'),
  ('admin_archive_store'),
  ('admin_restore_store'),
  ('admin_set_store_logo'),
  ('admin_set_bonus_cap'),
  ('admin_insert_reward_rule'),
  ('admin_delete_reward_rule'),
  ('admin_update_reward_rule_order'),
  ('admin_assign_manager'),
  ('admin_remove_manager'),
  ('admin_assign_staff'),
  ('admin_remove_staff'),
  ('admin_load_store_members'),
  ('admin_create_outlet'),
  ('admin_update_outlet'),
  ('admin_delete_outlet'),
  ('join_store'),
  ('load_customer_home'),
  ('mark_account_linked'),
  ('award_points'),
  ('adjust_points'),
  ('approve_staff_applicant'),
  ('demote_store_staff'),
  ('manager_remove_customer_from_store'),
  ('load_store_members'),
  ('load_store_outlets'),
  ('load_store_staff_profiles'),
  ('load_member_recent_transactions')
) AS t(fn)
WHERE NOT EXISTS (
  SELECT 1 FROM pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname  = 'public'
    AND  p.proname  = t.fn
    AND  p.prokind  = 'f'
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. CANONICAL FUNCTION SIGNATURES
-- Returns rows for any function whose exact argument signature is missing.
-- This catches signature drift (e.g. a parameter added/removed in a hot-fix).
-- ─────────────────────────────────────────────────────────────────────────────

SELECT t.fn AS function_name, t.expected_args AS expected_signature, 'not found' AS status
FROM (VALUES
  ('is_admin',                                ''),
  ('get_store_role',                          'uuid'),
  ('assert_store_access',                     'uuid'),
  ('assert_store_manager',                    'uuid'),
  ('assert_store_active',                     'uuid'),
  ('assert_active_membership',                'uuid, uuid'),
  ('create_profile',                          ''),
  ('admin_create_store',                      'text'),
  ('admin_update_store',                      'uuid, text'),
  ('admin_remove_store',                      'uuid'),
  ('admin_archive_store',                     'uuid'),
  ('admin_restore_store',                     'uuid'),
  ('admin_set_store_logo',                    'uuid, text'),
  ('admin_set_bonus_cap',                     'uuid, integer'),
  ('admin_insert_reward_rule',                'uuid, text, integer, text, integer'),
  ('admin_delete_reward_rule',                'uuid'),
  ('admin_update_reward_rule_order',          'uuid, integer'),
  ('admin_assign_manager',                    'uuid, uuid'),
  ('admin_remove_manager',                    'uuid, uuid'),
  ('admin_assign_staff',                      'uuid, uuid'),
  ('admin_remove_staff',                      'uuid, uuid'),
  ('admin_load_store_members',                'uuid'),
  ('admin_create_outlet',                     'uuid, text'),
  ('admin_update_outlet',                     'uuid, text'),
  ('admin_delete_outlet',                     'uuid'),
  ('join_store',                              'uuid'),
  ('load_customer_home',                      'boolean'),
  ('mark_account_linked',                     ''),
  ('award_points',                            'uuid, uuid, integer, text, uuid, uuid'),
  ('adjust_points',                           'uuid, uuid, integer, text, uuid'),
  ('approve_staff_applicant',                 'uuid, uuid'),
  ('demote_store_staff',                      'uuid, uuid'),
  ('manager_remove_customer_from_store',      'uuid, uuid'),
  ('load_store_members',                      'uuid'),
  ('load_store_outlets',                      'uuid'),
  ('load_store_staff_profiles',               'uuid'),
  ('load_member_recent_transactions',         'uuid, uuid')
) AS t(fn, expected_args)
WHERE NOT EXISTS (
  SELECT 1
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname  = 'public'
    AND  p.proname  = t.fn
    AND  pg_get_function_identity_arguments(p.oid) = t.expected_args
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. SECURITY DEFINER CHECK
-- Returns rows for any public function that is NOT SECURITY DEFINER.
-- Every function in this schema must be SECURITY DEFINER.
-- ─────────────────────────────────────────────────────────────────────────────

SELECT p.proname AS function_not_security_definer,
       pg_get_function_identity_arguments(p.oid) AS args
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname   = 'public'
  AND  p.prokind   = 'f'
  AND  p.prosecdef = false;  -- prosecdef = true means SECURITY DEFINER

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. EMPTY search_path CHECK
-- Returns rows for any public function that does NOT have search_path = ''.
-- An empty search_path is required to prevent schema-injection attacks.
-- ─────────────────────────────────────────────────────────────────────────────

SELECT p.proname AS function_missing_empty_search_path,
       pg_get_function_identity_arguments(p.oid) AS args,
       p.proconfig AS current_config
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public'
  AND  p.prokind = 'f'
  AND  NOT (p.proconfig @> ARRAY['search_path=']);

-- ─────────────────────────────────────────────────────────────────────────────
-- 10. NO ANON / PUBLIC GRANTS ON FUNCTIONS
-- Returns rows for any function still grantable to anon or PUBLIC.
-- Zero rows = good. Any row = privilege leak.
-- ─────────────────────────────────────────────────────────────────────────────

SELECT routine_name, grantee, privilege_type
FROM   information_schema.role_routine_grants
WHERE  routine_schema = 'public'
  AND  grantee IN ('anon', 'PUBLIC')
ORDER  BY routine_name;

-- ─────────────────────────────────────────────────────────────────────────────
-- 11. RLS POLICIES PRESENT
-- Returns rows for any expected policy that is missing.
-- ─────────────────────────────────────────────────────────────────────────────

SELECT t.tbl AS table_name, t.pol AS missing_policy
FROM (VALUES
  -- profiles
  ('profiles',           'profiles: select own'),
  ('profiles',           'profiles: select as admin'),
  -- stores
  ('stores',             'stores: allow select'),
  ('stores',             'stores: no direct insert'),
  ('stores',             'stores: no direct update'),
  ('stores',             'stores: no direct delete'),
  -- store_memberships
  ('store_memberships',  'memberships: select own'),
  ('store_memberships',  'memberships: no direct insert'),
  -- store_staff
  ('store_staff',        'staff: select self'),
  ('store_staff',        'staff: select as manager'),
  ('store_staff',        'staff: select as admin'),
  ('store_staff',        'staff: no direct insert'),
  ('store_staff',        'staff: no direct delete'),
  -- store_managers
  ('store_managers',     'managers: allow select'),
  ('store_managers',     'managers: no direct insert'),
  ('store_managers',     'managers: no direct delete'),
  -- points_ledger
  ('points_ledger',      'ledger: select own'),
  ('points_ledger',      'ledger: no direct insert'),
  -- store_reward_rules
  ('store_reward_rules', 'rules: allow select'),
  ('store_reward_rules', 'rules: no direct insert'),
  ('store_reward_rules', 'rules: no direct update'),
  ('store_reward_rules', 'rules: no direct delete'),
  -- admins
  ('admins',             'admins: service role only'),
  -- store_outlets
  ('store_outlets',      'outlets: authenticated read'),
  ('store_outlets',      'outlets: no direct insert'),
  ('store_outlets',      'outlets: no direct update'),
  ('store_outlets',      'outlets: no direct delete'),
  -- ab_variants
  ('ab_variants',        'ab_variants: allow select'),
  ('ab_variants',        'ab_variants: no direct insert'),
  ('ab_variants',        'ab_variants: no direct update'),
  ('ab_variants',        'ab_variants: no direct delete')
) AS t(tbl, pol)
WHERE NOT EXISTS (
  SELECT 1 FROM pg_policies
  WHERE  schemaname = 'public'
    AND  tablename  = t.tbl
    AND  policyname = t.pol
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 12. VIEW PRESENT
-- Returns a row if the admin_user_directory view is missing.
-- ─────────────────────────────────────────────────────────────────────────────

SELECT 'admin_user_directory view missing' AS problem
WHERE NOT EXISTS (
  SELECT 1 FROM pg_views
  WHERE schemaname = 'public'
    AND viewname   = 'admin_user_directory'
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 13. REALTIME PUBLICATION
-- Returns a row if points_ledger is not in the realtime publication.
-- ─────────────────────────────────────────────────────────────────────────────

SELECT 'points_ledger missing from supabase_realtime' AS problem
WHERE NOT EXISTS (
  SELECT 1 FROM pg_publication_tables
  WHERE pubname   = 'supabase_realtime'
    AND tablename = 'points_ledger'
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 14. STORAGE BUCKET
-- Returns a row if the store-logos bucket is missing.
-- ─────────────────────────────────────────────────────────────────────────────

SELECT 'store-logos bucket missing' AS problem
WHERE NOT EXISTS (
  SELECT 1 FROM storage.buckets
  WHERE id = 'store-logos'
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 15. AB VARIANTS SEED DATA
-- Returns a row if the required save_prompt variants are missing.
-- ─────────────────────────────────────────────────────────────────────────────

SELECT v.expected_variant AS missing_ab_variant
FROM (VALUES
  ('save_prompt', 'A'),
  ('save_prompt', 'B')
) AS v(test_name, expected_variant)
WHERE NOT EXISTS (
  SELECT 1 FROM public.ab_variants
  WHERE test_name = v.test_name
    AND variant   = v.expected_variant
);

-- ─────────────────────────────────────────────────────────────────────────────
-- SUMMARY: run all the above. Zero rows everywhere = baseline intact.
-- Any row = drift detected = investigation required before deploying.
-- ─────────────────────────────────────────────────────────────────────────────

-- BONUS: count all public functions as a quick sanity check.
-- Expect: 37 (the 37 non-trigger functions defined in BASELINE.md).
SELECT count(*) AS total_public_functions,
       CASE WHEN count(*) = 37 THEN 'OK' ELSE 'UNEXPECTED — baseline expects 37' END AS status
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'public'
  AND  p.prokind = 'f';
