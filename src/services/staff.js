import { supabase } from '../lib/supabase.js'
import { state } from '../state/state.js'

export async function loadStaffStores(userId) {
  const { data } = await supabase
    .from('store_staff')
    .select('store_id, stores(name)')
    .eq('user_id', userId)
  state.staffStores = data || []
}
