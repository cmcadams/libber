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

export async function loadMyApplications(userId) {
  const { data, error } = await supabase
    .from('store_staff_applicants')
    .select('store_id')
    .eq('user_id', userId)

  return { data: data ?? [], error }
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

export async function demoteStaff(userId, storeId) {
  return supabase.rpc('demote_store_staff', {
    p_user_id: userId,
    p_store_id: storeId
  })
}

export async function applyForManager(storeId) {
  return supabase.rpc('apply_for_manager', { p_store_id: storeId })
}

export async function loadMyManagerApplications(userId) {
  const { data, error } = await supabase
    .from('store_manager_applicants')
    .select('store_id')
    .eq('user_id', userId)
  return { data: data ?? [], error }
}

export async function rejectApplicant(userId, storeId) {
  return supabase.rpc('reject_staff_applicant', {
    p_user_id: userId,
    p_store_id: storeId
  })
}

export async function loadStaff(storeId) {
  const { data: staff, error } = await supabase
    .from('store_staff')
    .select('user_id, created_at')
    .eq('store_id', storeId)
    .order('created_at', { ascending: true })

  if (error || !staff?.length) return { data: staff ?? [], error }

  const userIds = staff.map(s => s.user_id)
  const { data: profiles } = await supabase
    .from('profiles')
    .select('user_id, public_id')
    .in('user_id', userIds)

  const profileMap = Object.fromEntries((profiles ?? []).map(p => [p.user_id, p.public_id]))

  return {
    data: staff.map(s => ({ ...s, public_id: profileMap[s.user_id] ?? null })),
    error: null
  }
}
