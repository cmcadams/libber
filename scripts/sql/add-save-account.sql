-- add-save-account.sql
--
-- Adds the mark_account_linked RPC used by the Save Your Points page.
-- Called after OAuth or magic-link identity linking completes.
--
-- Before deploying the save page, you must also configure the following in
-- the Supabase dashboard:
--
--   Authentication → Providers
--     Enable: Google, Apple, Facebook, GitHub
--     Add each provider's Client ID and Client Secret.
--
--   Authentication → URL Configuration → Redirect URLs
--     Add: https://<your-domain>/apps/customer/save.html
--     Add: http://localhost:5173/apps/customer/save.html  (for local dev)
--
--   Authentication → Sign In / Up
--     Enable "Allow anonymous sign-ins"  (should already be on)
--     Enable "Allow manual linking"      (required for linkIdentity to work)
--
-- Note: existing deployments that ran this file under the old name
-- (mark_email_saved / email_saved_at) should run rename-account-linked.sql
-- instead of this file.

CREATE OR REPLACE FUNCTION public.mark_account_linked()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE public.profiles
  SET    account_linked_at = now()
  WHERE  id                = auth.uid()
    AND  account_linked_at IS NULL;
END;
$$;

GRANT EXECUTE ON FUNCTION public.mark_account_linked() TO authenticated;
