import { supabase } from '../lib/supabase.js'

export async function getStores() {
  const { data, error } = await supabase
    .from('stores')
    .select('id, name')
    .order('name')
  return { data, error }
}

export async function joinStore(storeId) {
  const { data, error } = await supabase.rpc('join_store', {
    p_store_id: storeId
  })
  return { data, error }
}
