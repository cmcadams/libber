import { supabase } from '../lib/supabase.js'

export async function loadManagedStores() {
  return supabase
    .from('store_managers')
    .select('store_id, stores(name)')
    .order('created_at', { ascending: true })
}

export async function approveApplicant(userId, storeId) {
  return supabase.rpc('approve_staff_applicant', {
    p_user_id: userId,
    p_store_id: storeId
  })
}

export async function demoteStaff(userId, storeId) {
  return supabase.rpc('demote_store_staff', {
    p_user_id: userId,
    p_store_id: storeId
  })
}

export async function loadStaff(storeId) {
  const { data, error } = await supabase.rpc('load_store_staff_profiles', {
    p_store_id: storeId
  })
  return { data: data ?? [], error }
}
