import { captureError } from '../../lib/sentry.js'
import { initAuth } from '../../services/auth.js'
import { loadMembers, loadUserProfile } from '../../services/members.js'
import { loadRewardRules } from '../../services/admin.js'
import { getStoreBonusCap } from '../../services/stores.js'
import { loadManagedStores } from '../../services/applicants.js'
import { loadStaffStores } from '../../services/staff.js'
import { state } from '../../state/state.js'
import { loadSelectedStore, saveSelectedStore } from '../../lib/storage.js'
import { renderCustomers, initCustomerHandlers } from '../../ui/renderCustomers.js'
import { toHumanId } from '../../lib/format.js'
import { $ } from '../../lib/dom.js'
import { escapeHtml } from '../../lib/escape.js'

if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('/apps/staff/sw.js').catch(() => {})
}

let managedStores = []
let loadToken = 0

async function boot() {
  $('backBtn')?.addEventListener('click', openStorePicker)
  bindStorePickerEvents()

  try {
    const user = await initAuth()
    if (!user) return

    loadSelectedStore()

    if (!state.selectedStoreId) return

    const [{ data: profile }] = await Promise.all([
      loadUserProfile(user.id),
      loadStaffStores(user.id),
      loadManagedStores().then(({ data }) => { managedStores = data || [] })
    ])
    const publicId = toHumanId(profile?.public_id, user.id)
    $('staffId').textContent = publicId

    await loadStore(state.selectedStoreId)
    initCustomerHandlers()

    const refreshBtn = $('refreshBtn')
    if (refreshBtn) {
      refreshBtn.addEventListener('click', async () => {
        refreshBtn.classList.add('loading')
        refreshBtn.disabled = true
        try {
          await loadStore(state.selectedStoreId)
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

function openStorePicker() {
  const stores = state.staffStores || []
  let html = stores.map(s => `
    <div class="customer-row" data-pick-store-id="${escapeHtml(s.store_id)}" data-pick-store-name="${escapeHtml(s.stores?.name || 'Store')}">
      <span class="cust-id">${escapeHtml(s.stores?.name || 'Untitled store')}</span>
      ${s.store_id === state.selectedStoreId ? '<span class="cust-pts">current</span>' : ''}
    </div>
  `).join('')

  if (managedStores.length) {
    html += `
    <div class="customer-row store-pick-row" data-pick-manager>
      <span class="cust-id">Manager tools</span>
      <span class="cust-pts">→</span>
    </div>`
  }

  $('storePickerList').innerHTML = html || '<div class="empty">No stores available</div>'
  $('storePicker').classList.add('open')
}

async function loadStore(storeId) {
  const token = ++loadToken
  const [
    { error: membersError },
    { data: rules, error: rulesError },
    { data: cap }
  ] = await Promise.all([
    loadMembers(storeId),
    loadRewardRules(storeId),
    getStoreBonusCap(storeId)
  ])
  if (token !== loadToken) return
  if (membersError || rulesError) throw membersError || rulesError
  state.rewardRules = rules || []
  state.bonusCap = cap
  const storeEntry = (state.staffStores || []).find(s => s.store_id === storeId)
  $('storeTitle').textContent = storeEntry?.stores?.name || state.selectedStoreName || ''
  renderCustomers()
}

function bindStorePickerEvents() {
  $('storePickerClose')?.addEventListener('click', () => $('storePicker').classList.remove('open'))

  $('storePicker')?.addEventListener('click', async e => {
    if (e.target === $('storePicker')) {
      $('storePicker').classList.remove('open')
      return
    }
    const managerRow = e.target.closest('[data-pick-manager]')
    if (managerRow) {
      window.location.href = '/apps/staff/manager.html'
      return
    }
    const storeRow = e.target.closest('[data-pick-store-id]')
    if (storeRow) {
      saveSelectedStore(storeRow.dataset.pickStoreId, storeRow.dataset.pickStoreName)
      $('storePicker').classList.remove('open')
      await loadStore(state.selectedStoreId)
    }
  })
}

boot()
