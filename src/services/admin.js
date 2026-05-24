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
    .select('id, name, logo_path, logo_updated_at, is_active, deleted_at')
    .order('name', { ascending: true })
}

export async function uploadStoreLogo(storeId, blob) {
  const path = `stores/${storeId}/logo.webp`
  return supabase.storage
    .from('store-logos')
    .upload(path, blob, { contentType: 'image/webp', upsert: true })
}

export async function setStoreLogo(storeId, logoPath) {
  return supabase.rpc('admin_set_store_logo', {
    p_store_id:  storeId,
    p_logo_path: logoPath,
  })
}

export async function setBonusCap(storeId, maxBonus) {
  return supabase.rpc('admin_set_bonus_cap', {
    p_store_id: storeId,
    p_max_bonus_points: maxBonus
  })
}

export async function loadRewardRules(storeId) {
  return supabase
    .from('store_reward_rules')
    .select('id, label, points, kind, sort_order')
    .eq('store_id', storeId)
    .eq('is_active', true)
    .order('sort_order', { ascending: true })
}

export async function loadStoreManagers(storeId) {
  return supabase
    .from('store_managers')
    .select('user_id')
    .eq('store_id', storeId)
}

export async function loadStoreStaff(storeId) {
  return supabase
    .from('store_staff')
    .select('user_id')
    .eq('store_id', storeId)
}

export async function loadStoreMembers(storeId) {
  return supabase.rpc('admin_load_store_members', { p_store_id: storeId })
}


// ── Store RPCs ────────────────────────────────────────────────────────────────

export async function createStore(name) {
  return supabase.rpc('admin_create_store', { p_name: name })
}

export async function updateStoreName(id, name) {
  return supabase.rpc('admin_update_store', { p_store_id: id, p_name: name })
}

export async function removeStore(id) {
  return supabase.rpc('admin_remove_store', { p_store_id: id })
}

// ── Reward rule RPCs ──────────────────────────────────────────────────────────

export async function insertRewardRule(storeId, { label, points, kind }, sortOrder) {
  return supabase.rpc('admin_insert_reward_rule', {
    p_store_id:   storeId,
    p_label:      label,
    p_points:     points,
    p_kind:       kind,
    p_sort_order: sortOrder
  })
}

export async function deleteRewardRule(id) {
  return supabase.rpc('admin_delete_reward_rule', { p_id: id })
}

export async function updateRewardRuleOrder(id, sortOrder) {
  return supabase.rpc('admin_update_reward_rule_order', { p_id: id, p_sort_order: sortOrder })
}

// ── Outlet RPCs ───────────────────────────────────────────────────────────────

export async function loadStoreOutlets(storeId) {
  return supabase.rpc('load_store_outlets', { p_store_id: storeId })
}

export async function createOutlet(storeId, name) {
  return supabase.rpc('admin_create_outlet', { p_store_id: storeId, p_name: name })
}

export async function updateOutlet(outletId, name) {
  return supabase.rpc('admin_update_outlet', { p_outlet_id: outletId, p_name: name })
}

export async function deleteOutlet(outletId) {
  return supabase.rpc('admin_delete_outlet', { p_outlet_id: outletId })
}

export async function archiveStore(storeId) {
  return supabase.rpc('admin_archive_store', { p_store_id: storeId })
}

export async function restoreStore(storeId) {
  return supabase.rpc('admin_restore_store', { p_store_id: storeId })
}

export async function removeCustomerFromStore(userId, storeId) {
  return supabase.rpc('manager_remove_customer_from_store', {
    p_user_id:  userId,
    p_store_id: storeId,
  })
}

// ── Staff / manager RPCs ──────────────────────────────────────────────────────

export async function assignManager(userId, storeId) {
  return supabase.rpc('admin_assign_manager', { p_user_id: userId, p_store_id: storeId })
}

export async function assignStaff(userId, storeId) {
  return supabase.rpc('admin_assign_staff', { p_user_id: userId, p_store_id: storeId })
}

export async function removeManager(userId, storeId) {
  return supabase.rpc('admin_remove_manager', { p_user_id: userId, p_store_id: storeId })
}

export async function removeStaffAdmin(userId, storeId) {
  return supabase.rpc('admin_remove_staff', { p_user_id: userId, p_store_id: storeId })
}

