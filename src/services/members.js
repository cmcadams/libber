import { supabase } from '../lib/supabase.js'
import { state } from '../state/state.js'
import { toHumanId } from '../lib/format.js'
import { captureError } from '../lib/sentry.js'

export async function loadUserProfile(userId) {
  const { data: profile, error } = await supabase
    .from('profiles')
    .select('user_id, public_id')
    .eq('user_id', userId)
    .single()

  if (error) captureError(error, { fn: 'loadUserProfile' })
  return { data: profile ?? null, error }
}


export async function loadPointsHistory(userId, storeId) {
  return supabase
    .from('points_ledger')
    .select('points, reason, created_at')
    .eq('user_id', userId)
    .eq('store_id', storeId)
    .order('created_at', { ascending: false })
    .limit(10)
}

export async function loadCustomerHome(includeStores = true) {
  const { data, error } = await supabase.rpc('load_customer_home', {
    p_include_stores: includeStores
  })
  if (error) captureError(error, { fn: 'loadCustomerHome' })
  return { data: data ?? null, error }
}

export function subscribeToPointsInserts(userId, onInsert) {
  return supabase
    .channel(`points-inserts-${userId}`)
    .on('postgres_changes', {
      event: 'INSERT',
      schema: 'public',
      table: 'points_ledger',
      filter: `user_id=eq.${userId}`
    }, payload => onInsert(payload.new))
    .subscribe()
}

export async function loadMembers(storeId) {
  const { data, error } = await supabase.rpc('load_store_members', { p_store_id: storeId })

  if (error) {
    captureError(error, { fn: 'loadMembers' })
    state.members = []
  } else {
    state.members = (data || []).map(m => ({
      user_id: m.user_id,
      public_id: toHumanId(m.public_id, m.user_id),
      balance: m.balance ?? 0
    }))
  }

  return { error }
}

export async function awardPoints(userId, storeId, points, reason, ruleId = null, outletId = null) {
  const params = { p_user_id: userId, p_store_id: storeId, p_points: points, p_reason: reason }
  if (ruleId)   params.p_rule_id   = ruleId
  if (outletId) params.p_outlet_id = outletId
  const { error } = await supabase.rpc('award_points', params)
  return { error }
}

export async function adjustPoints(userId, storeId, points, reason, outletId = null) {
  const params = { p_user_id: userId, p_store_id: storeId, p_points: points, p_reason: reason }
  if (outletId) params.p_outlet_id = outletId
  const { error } = await supabase.rpc('adjust_points', params)
  return { error }
}

export async function loadMemberRecentTransactions(userId, storeId) {
  const { data, error } = await supabase.rpc('load_member_recent_transactions', {
    p_user_id:  userId,
    p_store_id: storeId
  })
  if (error) captureError(error, { fn: 'loadMemberRecentTransactions' })
  return { data: data ?? [], error }
}
