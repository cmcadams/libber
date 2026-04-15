import { supabase } from '../lib/supabase.js'
import { state } from '../state/state.js'

export async function loadAllStaff() {
  const { data, error } = await supabase
    .from('store_staff')
    .select('id, user_id, store_id, stores(name)')
  state.allStaff = data || []
  return { data, error }
}

export async function loadAdminUsers() {
  return supabase
    .from('admin_user_directory')
    .select('user_id, public_id')
    .order('public_id', { ascending: true })
}

export async function loadAllStores() {
  return supabase
    .from('stores')
    .select('id, name')
    .order('name', { ascending: true })
}

export async function assignManager(userId, storeId) {
  return supabase.rpc('admin_assign_manager', {
    p_user_id: userId,
    p_store_id: storeId
  })
}
