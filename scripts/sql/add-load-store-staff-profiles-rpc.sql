-- add-load-store-staff-profiles-rpc.sql
--
-- Single-query RPC that replaces the two-round-trip loadStaff() client
-- implementation (store_staff query → profiles query).
-- Callers must be a manager of the requested store.

CREATE OR REPLACE FUNCTION public.load_store_staff_profiles(p_store_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.store_managers
    WHERE store_id = p_store_id AND user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  RETURN (
    SELECT COALESCE(json_agg(json_build_object(
      'user_id',    ss.user_id,
      'public_id',  p.public_id,
      'created_at', ss.created_at
    ) ORDER BY ss.created_at), '[]'::json)
    FROM public.store_staff ss
    LEFT JOIN public.profiles p ON p.user_id = ss.user_id
    WHERE ss.store_id = p_store_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.load_store_staff_profiles(uuid) TO authenticated;
