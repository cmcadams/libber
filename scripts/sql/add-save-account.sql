-- add-save-account.sql
--
-- Adds the mark_email_saved RPC used by the Save Your Points page.
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

CREATE OR REPLACE FUNCTION public.mark_email_saved()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE public.profiles
  SET    email_saved_at = now()
  WHERE  id             = auth.uid()
    AND  email_saved_at IS NULL;
END;
$$;

GRANT EXECUTE ON FUNCTION public.mark_email_saved() TO authenticated;
