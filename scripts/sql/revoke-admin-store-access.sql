-- revoke-admin-store-access.sql
-- Revokes global admin role and all store manager access for one user,
-- identified by public_id. Idempotent — safe to re-run.
--
-- USAGE:
--   1. Set v_target_public_id to the target user's public_id.
--   2. Run with v_dry_run = true (default) to preview what will change.
--   3. Confirm the output, set v_dry_run = false, and run again to commit.
--
-- Run in: Supabase Dashboard → SQL Editor (executes as postgres superuser).

DO $$
DECLARE
  -- ── CONFIG — edit these before running ────────────────────────────────────
  v_target_public_id  text    := 'PUT_PUBLIC_ID_HERE';
  v_dry_run           boolean := true;   -- MUST set to false to commit

  -- ── STATE — do not edit ───────────────────────────────────────────────────
  v_target_user_id    uuid;
  v_match_count       int;
  v_preview_admin     int;
  v_preview_managers  int;
  v_removed_admin     int;
  v_removed_managers  int;
BEGIN

  -- ── 1. VALIDATE INPUT ─────────────────────────────────────────────────────
  IF v_target_public_id IS NULL
     OR trim(v_target_public_id) = ''
     OR v_target_public_id = 'PUT_PUBLIC_ID_HERE'
  THEN
    RAISE EXCEPTION
      'Set v_target_public_id to the target user''s public_id before running';
  END IF;

  -- ── 2. RESOLVE IDENTITY ───────────────────────────────────────────────────
  -- Single scan: COUNT + MIN(user_id) together prevents two-query TOCTOU.
  -- MIN is deterministic when COUNT = 1; raises exception before any DML if not.
  SELECT COUNT(*), MIN(user_id)
  INTO   v_match_count, v_target_user_id
  FROM   public.profiles
  WHERE  public_id = trim(v_target_public_id);

  IF v_match_count = 0 THEN
    RAISE EXCEPTION
      'No profile found with public_id = ''%''', v_target_public_id;
  END IF;

  IF v_match_count > 1 THEN
    RAISE EXCEPTION
      'Data integrity violation: % rows share public_id ''%'' — cannot proceed safely',
      v_match_count, v_target_public_id;
  END IF;

  -- ── 3. SELF-REVOKE PROTECTION ─────────────────────────────────────────────
  -- auth.uid() returns NULL when running as the postgres superuser (SQL Editor).
  -- When non-null (e.g. called via RPC), the equality check is enforced.
  -- In SQL Editor context, the caller must verify manually (see warning below).
  IF auth.uid() IS NOT NULL AND v_target_user_id = auth.uid() THEN
    RAISE EXCEPTION 'Self-revocation is not permitted';
  END IF;

  IF auth.uid() IS NULL THEN
    RAISE WARNING
      'Running as superuser — self-revoke check cannot be enforced. '
      'Verify that ''%'' is not your own account before proceeding.',
      v_target_public_id;
  END IF;

  -- ── 4. PREVIEW WHAT WILL BE REMOVED ──────────────────────────────────────
  SELECT COUNT(*) INTO v_preview_admin
  FROM   public.admins
  WHERE  user_id = v_target_user_id;

  SELECT COUNT(*) INTO v_preview_managers
  FROM   public.store_managers
  WHERE  user_id = v_target_user_id;

  IF v_preview_admin = 0 AND v_preview_managers = 0 THEN
    RAISE NOTICE
      'User ''%'' (%) has no admin or manager rows — nothing to revoke.',
      v_target_public_id, v_target_user_id;
  END IF;

  -- ── 5. DRY RUN OUTPUT ────────────────────────────────────────────────────
  IF v_dry_run THEN
    RAISE NOTICE '------------------------------------------------------------';
    RAISE NOTICE 'DRY RUN — no changes made (set v_dry_run = false to commit)';
    RAISE NOTICE '  public_id          : %', v_target_public_id;
    RAISE NOTICE '  user_id            : %', v_target_user_id;
    RAISE NOTICE '  admin rows to drop : %', v_preview_admin;
    RAISE NOTICE '  manager rows to drop: %', v_preview_managers;
    RAISE NOTICE '------------------------------------------------------------';
    RETURN;
  END IF;

  -- ── 6. EXECUTE ───────────────────────────────────────────────────────────
  DELETE FROM public.admins         WHERE user_id = v_target_user_id;
  GET DIAGNOSTICS v_removed_admin    = ROW_COUNT;

  DELETE FROM public.store_managers WHERE user_id = v_target_user_id;
  GET DIAGNOSTICS v_removed_managers = ROW_COUNT;

  -- ── 7. AUDIT OUTPUT ──────────────────────────────────────────────────────
  RAISE NOTICE '------------------------------------------------------------';
  RAISE NOTICE 'REVOCATION COMPLETE';
  RAISE NOTICE '  public_id          : %', v_target_public_id;
  RAISE NOTICE '  user_id            : %', v_target_user_id;
  RAISE NOTICE '  admin rows removed : %', v_removed_admin;
  RAISE NOTICE '  manager rows removed: %', v_removed_managers;
  RAISE NOTICE '------------------------------------------------------------';

END $$;
