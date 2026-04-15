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

export function subscribeToUserPointsUpdates(userId, onUpdate) {
  console.log('Setting up real-time subscription for user:', userId)
  
  const channel = supabase
    .channel(`user-points-${userId}`)
    .on(
      'postgres_changes',
      {
        event: 'INSERT',
        schema: 'public',
        table: 'points_ledger',
        filter: `user_id=eq.${userId}`
      },
      async (payload) => {
        console.log('🔔 Points update received:', payload)
        await loadUserStoresWithPoints(userId)
        onUpdate()
      }
    )
    .subscribe((status) => {
      console.log('Subscription status:', status)
      if (status === 'SUBSCRIBED') {
        console.log('✅ Real-time points subscription ACTIVE')
      } else {
        console.log('❌ Real-time subscription failed:', status)
      }
    })

  return channel
}

export function unsubscribeFromPointsUpdates(channel) {
  if (channel) {
    supabase.removeChannel(channel)
  }
}

export async function loadMembers(storeId) {
  // fetch memberships for this store
  const { data: memberships, error } = await supabase
    .from('store_memberships')
    .select('user_id')
    .eq('store_id', storeId)

  if (error) {
    console.error('loadMembers: memberships error', error)
    state.members = []
    return
  }

  const userIds = memberships.map(m => m.user_id)
  if (!userIds.length) {
    state.members = []
    return
  }

  // fetch latest running_balance per user from ledger
  const { data: ledger, error: ledgerError } = await supabase
    .from('points_ledger')
    .select('user_id, running_balance, created_at')
    .eq('store_id', storeId)
    .in('user_id', userIds)
    .order('created_at', { ascending: false })

  if (ledgerError) {
    console.error('loadMembers: ledger error', ledgerError)
  }

  // latest balance per user — ledger is ordered desc so first hit wins
  const balanceMap = {}
  for (const row of (ledger || [])) {
    if (!(row.user_id in balanceMap)) {
      balanceMap[row.user_id] = row.running_balance
    }
  }

  // fetch public_ids from profiles
  const { data: profiles, error: profilesError } = await supabase
    .from('profiles')
    .select('user_id, public_id')
    .in('user_id', userIds)

  if (profilesError) {
    console.error('loadMembers: profiles error', profilesError)
  }

  const profileMap = {}
  for (const p of (profiles || [])) {
    profileMap[p.user_id] = p.public_id
  }

  state.members = userIds.map(uid => ({
    user_id: uid,
    public_id: profileMap[uid] || `USR-${uid.slice(0, 6).toUpperCase()}`,
    balance: balanceMap[uid] ?? 0,
  }))
}

export async function awardPoints(userId, storeId, points, reason) {
  const { error } = await supabase.rpc('award_points', {
    p_user_id: userId,
    p_store_id: storeId,
    p_points: points,
    p_reason: reason,
  })

  if (error) throw error
}
