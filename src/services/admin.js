import { supabase } from '../lib/supabase.js'

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

export async function assignStaff(userId, storeId) {
  return supabase
    .from('store_staff')
    .insert({ user_id: userId, store_id: storeId })
}

export async function createStore(name) {
  return supabase
    .from('stores')
    .insert({ name: name.trim() })
    .select('id, name')
    .single()
}

export async function updateStoreName(id, name) {
  return supabase
    .from('stores')
    .update({ name: name.trim() })
    .eq('id', id)
    .select('id, name')
    .single()
}

export async function removeStore(id) {
  return supabase
    .from('stores')
    .delete()
    .eq('id', id)
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

export async function loadStoreManagers(storeId) {
  return supabase
    .from('store_managers')
    .select('user_id')
    .eq('store_id', storeId)
}

export async function removeManager(userId, storeId) {
  return supabase
    .from('store_managers')
    .delete()
    .eq('user_id', userId)
    .eq('store_id', storeId)
}

export async function loadStoreStaff(storeId) {
  return supabase
    .from('store_staff')
    .select('user_id')
    .eq('store_id', storeId)
}

export async function removeStaffAdmin(userId, storeId) {
  return supabase
    .from('store_staff')
    .delete()
    .eq('user_id', userId)
    .eq('store_id', storeId)
}

export async function loadStoreApplicants(storeId) {
  return supabase
    .from('store_staff_applicants')
    .select('user_id, store_id')
    .eq('store_id', storeId)
    .order('created_at', { ascending: false })
}

export async function loadAllApplicants() {
  return supabase
    .from('store_staff_applicants')
    .select('user_id, store_id')
    .order('created_at', { ascending: false })
}

export async function approveApplicantAdmin(userId, storeId) {
  const { error: insertError } = await supabase
    .from('store_staff')
    .insert({ user_id: userId, store_id: storeId })
  if (insertError) return { error: insertError }
  return supabase
    .from('store_staff_applicants')
    .delete()
    .eq('user_id', userId)
    .eq('store_id', storeId)
}

export async function rejectApplicant(userId, storeId) {
  return supabase
    .from('store_staff_applicants')
    .delete()
    .eq('user_id', userId)
    .eq('store_id', storeId)
}
