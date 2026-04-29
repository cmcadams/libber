import { captureError } from '../../lib/sentry.js'

if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('/apps/staff/sw.js').catch(() => {})
}
import { initAuth } from '../../services/auth.js'
import { loadMembers, loadUserProfile } from '../../services/members.js'
import { loadRewardRules } from '../../services/admin.js'
import { getStoreBonusCap } from '../../services/stores.js'
import { state } from '../../state/state.js'
import { loadSelectedStore } from '../../lib/storage.js'
import { renderCustomers, initCustomerHandlers } from '../../ui/renderCustomers.js'
import { toHumanId } from '../../lib/format.js'
import { $ } from '../../lib/dom.js'

async function boot() {
  try {
    const user = await initAuth()
    if (!user) return

    // load selected store from localStorage
    loadSelectedStore()

    if (!state.selectedStoreId) {
      $('storeName').textContent = 'No store selected'
      return
    }

    // render store name + staff badge
    $('storeName').textContent = state.selectedStoreName || 'Store'

    const { data: profile } = await loadUserProfile(user.id)
    const publicId = toHumanId(profile?.public_id, user.id)
    $('staffBadge').textContent = `Staff: ${publicId}`

    // load members and reward rules for this store
    const [{ error: membersError }, { data: rules }, { data: cap }] = await Promise.all([
      loadMembers(state.selectedStoreId),
      loadRewardRules(state.selectedStoreId),
      getStoreBonusCap(state.selectedStoreId)
    ])
    if (membersError) throw membersError
    state.rewardRules = rules || []
    state.bonusCap = cap

    // render list + wire all handlers
    renderCustomers()
    initCustomerHandlers()

    const refreshBtn = $('refreshBtn')
    if (refreshBtn) {
      refreshBtn.addEventListener('click', async () => {
        refreshBtn.classList.add('loading')
        refreshBtn.disabled = true
        try {
          const { error } = await loadMembers(state.selectedStoreId)
          if (error) throw error
          renderCustomers()
        } catch (err) {
          captureError(err, { fn: 'refresh' })
        } finally {
          refreshBtn.classList.remove('loading')
          refreshBtn.disabled = false
        }
      })
    }
  } catch (err) {
    captureError(err)
    alert('Something went wrong loading the page.')
  }
}

boot()
