import { initAuth } from '../../services/auth.js'
import { loadMembers, loadUserProfile } from '../../services/members.js'
import { loadRewardRules } from '../../services/admin.js'
import { getStoreBonusCap } from '../../services/stores.js'
import { state } from '../../state/state.js'
import { loadSelectedStore } from '../../lib/storage.js'
import { renderCustomers, initCustomerHandlers } from '../../ui/renderCustomers.js'

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

  const profile = await loadUserProfile(user.id)
  const publicId = profile?.public_id || `USR-${user.id.slice(0, 6).toUpperCase()}`
  document.getElementById('staffBadge').textContent = `Staff: ${publicId}`

  // load members and reward rules for this store
  const [, { data: rules }, { data: cap }] = await Promise.all([
    loadMembers(state.selectedStoreId),
    loadRewardRules(state.selectedStoreId),
    getStoreBonusCap(state.selectedStoreId)
  ])
  state.rewardRules = rules || []
  state.bonusCap = cap

  // render list + wire all handlers
  renderCustomers()
  initCustomerHandlers()

  const refreshBtn = document.getElementById('refreshBtn')
  if (refreshBtn) {
    refreshBtn.addEventListener('click', async () => {
      refreshBtn.classList.add('loading')
      refreshBtn.disabled = true
      await loadMembers(state.selectedStoreId)
      renderCustomers()
      refreshBtn.classList.remove('loading')
      refreshBtn.disabled = false
    })
  }
}

boot()
