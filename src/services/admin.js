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

export async function createStore(name) {
  return supabase
    .from('stores')
    .insert({ name: name.trim() })
    .select('id, name')
    .single()
}

export async function loadRewardRules(storeId) {
  return supabase
    .from('store_reward_rules')
    .select('id, label, points, kind, sort_order')
    .eq('store_id', storeId)
    .eq('is_active', true)
    .order('sort_order', { ascending: true })
}

export async function insertRewardRule(storeId, { label, points, kind }, sortOrder) {
  return supabase
    .from('store_reward_rules')
    .insert({ store_id: storeId, label, points, kind, sort_order: sortOrder, is_active: true, is_pinned: false })
    .select('id, label, points, kind, sort_order')
    .single()
}

export async function deleteRewardRule(id) {
  return supabase
    .from('store_reward_rules')
    .delete()
    .eq('id', id)
}

export async function updateRewardRuleOrder(id, sortOrder) {
  return supabase
    .from('store_reward_rules')
    .update({ sort_order: sortOrder })
    .eq('id', id)
}
