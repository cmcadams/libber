import { supabase } from '../lib/supabase.js'

export async function applyForStaff(storeId) {
  return supabase.rpc('apply_for_staff', {
    p_store_id: storeId
  })
}

export async function loadManagedStores() {
  return supabase
    .from('store_managers')
    .select('store_id, stores(name)')
    .order('created_at', { ascending: true })
}

export async function loadApplicants(storeId) {
  return supabase
    .from('staff_applicant_directory')
    .select('user_id, store_id, created_at, public_id, store_name')
    .eq('store_id', storeId)
    .order('created_at', { ascending: false })
}

export async function approveApplicant(userId, storeId) {
  return supabase.rpc('approve_staff_applicant', {
    p_user_id: userId,
    p_store_id: storeId
  })
}
