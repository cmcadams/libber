import { supabase } from '../lib/supabase.js'

export async function getStores() {
  const { data, error } = await supabase
    .from('stores')
    .select('id, name')
    .order('name')
  return { data, error }
}

export async function getStoreBonusCap(storeId) {
  const { data, error } = await supabase
    .from('stores')
    .select('max_bonus_points')
    .eq('id', storeId)
    .single()
  return { data: data?.max_bonus_points ?? null, error }
}

export async function joinStore(storeId) {
  const { data, error } = await supabase.rpc('join_store', {
    p_store_id: storeId
  })
  return { data, error }
}

export async function unjoinStore(storeId) {
  const { data, error } = await supabase.rpc('unjoin_store', {
    p_store_id: storeId
  })
  return { data, error }
}
