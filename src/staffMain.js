import { initAuth } from './services/auth.js'
import { loadMembers } from './services/members.js'
import { state } from './state/state.js'
import { loadSelectedStore } from './lib/storage.js'
import { renderCustomers, initCustomerHandlers } from './ui/renderCustomers.js'

async function boot() {
  const user = await initAuth()
  if (!user) return

  // load selected store from localStorage
  loadSelectedStore()

  if (!state.selectedStoreId) {
    document.getElementById('storeName').textContent = 'No store selected'
    return
  }

  // render store name + staff badge
  document.getElementById('storeName').textContent = state.selectedStoreName || 'Store'
  document.getElementById('staffBadge').textContent = `Staff: ${user.id.slice(0, 6).toUpperCase()}`

  // load members for this store
  await loadMembers(state.selectedStoreId)

  // render list + wire all handlers
  renderCustomers()
  initCustomerHandlers()
}

boot()
