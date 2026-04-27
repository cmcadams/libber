import { supabase } from '../lib/supabase.js'
import { state } from '../state/state.js'

export async function loadStaffStores(userId) {
  const [{ data: staffRows, error: e1 }, { data: managerRows, error: e2 }] = await Promise.all([
    supabase.from('store_staff').select('store_id, stores(name)').eq('user_id', userId),
    supabase.from('store_managers').select('store_id, stores(name)').eq('user_id', userId)
  ])
  const seen = new Set()
  const merged = []
  for (const row of [...(staffRows || []), ...(managerRows || [])]) {
    if (!seen.has(row.store_id)) { seen.add(row.store_id); merged.push(row) }
  }
  state.staffStores = merged
  return { error: e1 || e2 || null }
}
