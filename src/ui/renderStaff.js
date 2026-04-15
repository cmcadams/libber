import { state } from '../state/state.js'
import { supabase } from '../lib/supabase.js'

export function renderStaff() {
  const el = document.getElementById('staff')
  el.innerHTML = `
    <h2>Staff</h2>
    <select id="storeSelect">
      <option value="">Select store</option>
      ${state.staffStores.map(s => `
        <option value="${s.store_id}">
          ${s.stores?.name}
        </option>
      `).join('')}
    </select>
  `
  document.getElementById('storeSelect')
    .addEventListener('change', async (e) => {
      state.selectedStoreId = e.target.value
    })
}

window.givePoints = async (userId) => {
  await supabase.from('points_ledger').insert({
    user_id: userId,
    store_id: state.selectedStoreId,
    points: 10,
    reason: 'staff award',
    created_by: state.user.id
  })
  alert('Points added')
}
