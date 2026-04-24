import { supabase } from '../lib/supabase.js'
import { state } from '../state/state.js'

export async function loadUserProfile(userId) {
  const { data: profile, error } = await supabase
    .from('profiles')
    .select('user_id, public_id')
    .eq('user_id', userId)
    .single()

  if (error) {
    console.error('loadUserProfile: error', error)
    return null
  }

  return profile
}

export async function loadUserStoresWithPoints(userId) {
  // fetch stores user is member of
  const { data: memberships, error: membError } = await supabase
    .from('store_memberships')
    .select('store_id, stores(id, name)')
    .eq('user_id', userId)

  if (membError) {
    console.error('loadUserStoresWithPoints: membership error', membError)
    state.userStores = []
    return
  }

  if (!memberships?.length) {
    state.userStores = []
    return
  }

  const storeIds = memberships.map(m => m.store_id)

  // fetch latest balance per store from ledger
  const { data: ledger, error: ledgerError } = await supabase
    .from('points_ledger')
    .select('store_id, running_balance, created_at')
    .eq('user_id', userId)
    .in('store_id', storeIds)
    .order('created_at', { ascending: false })

  if (ledgerError) {
    console.error('loadUserStoresWithPoints: ledger error', ledgerError)
  }

  // latest balance per store
  const balanceMap = {}
  for (const row of (ledger || [])) {
    if (!(row.store_id in balanceMap)) {
      balanceMap[row.store_id] = row.running_balance
    }
  }

  state.userStores = memberships.map(m => ({
    store_id: m.store_id,
    store_name: m.stores?.name || 'Unknown Store',
    balance: balanceMap[m.store_id] ?? 0
  }))
}


export async function loadPointsHistory(userId, storeId) {
  return supabase
    .from('points_ledger')
    .select('points, reason, created_at')
    .eq('user_id', userId)
    .eq('store_id', storeId)
    .order('created_at', { ascending: false })
    .limit(20)
}

export async function loadCustomerHome(includeStores = true) {
  const { data, error } = await supabase.rpc('load_customer_home', {
    p_include_stores: includeStores
  })
  if (error) {
    console.error('loadCustomerHome error', error)
    return null
  }
  return data
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
    console.error('loadMembers error', error)
    state.members = []
    return
  }

  state.members = (data || []).map(m => ({
    user_id: m.user_id,
    public_id: m.public_id || `USR-${m.user_id.slice(0, 6).toUpperCase()}`,
    balance: m.balance ?? 0
  }))
}

export async function awardPoints(userId, storeId, points, reason, ruleId = null) {
  const params = { p_user_id: userId, p_store_id: storeId, p_points: points, p_reason: reason }
  if (ruleId) params.p_rule_id = ruleId

  const { error } = await supabase.rpc('award_points', params)
  if (error) throw error
}
