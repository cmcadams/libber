import { captureError } from '../../lib/sentry.js'
import { initAuth } from '../../services/auth.js'
import { loadMembers, loadUserProfile } from '../../services/members.js'
import { loadRewardRules } from '../../services/admin.js'
import { getStoreBonusCap } from '../../services/stores.js'
import { loadManagedStores } from '../../services/applicants.js'
import { loadStaffStores, loadStoreOutlets } from '../../services/staff.js'
import { state } from '../../state/state.js'
import {
  loadSelectedStore, saveSelectedStore,
  loadSelectedOutlet, saveSelectedOutlet, clearSelectedOutlet,
} from '../../lib/storage.js'
import { renderCustomers, initCustomerHandlers } from '../../ui/renderCustomers.js'
import { toHumanId } from '../../lib/format.js'
import { $ } from '../../lib/dom.js'
import { escapeHtml } from '../../lib/escape.js'
import { migrateStorage } from '../../lib/migrate.js'

migrateStorage()

if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('/apps/staff/sw.js').catch(() => {})
}

let managedStores = []
let loadToken = 0

// ── Context display ───────────────────────────────────────────────────────────

function applyContext() {
  const storeEntry = (state.staffStores || []).find(s => s.store_id === state.selectedStoreId)
  const storeName  = storeEntry?.stores?.name || state.selectedStoreName || ''
  $('storeTitle').textContent = state.selectedOutletName || storeName

  const changeOutletBtn = $('changeOutletBtn')
  if (changeOutletBtn) {
    changeOutletBtn.style.display = state.storeOutlets.length > 0 ? '' : 'none'
  }
}

// ── Store picker ──────────────────────────────────────────────────────────────

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
    if (!storeRow) return

    const newStoreId   = storeRow.dataset.pickStoreId
    const newStoreName = storeRow.dataset.pickStoreName
    if (newStoreId !== state.selectedStoreId) {
      // Outlet from previous store is no longer valid
      clearSelectedOutlet()
      saveSelectedStore(newStoreId, newStoreName)
    }
    $('storePicker').classList.remove('open')
    await loadStore(state.selectedStoreId)
  })
}

// ── Outlet picker ─────────────────────────────────────────────────────────────

function openOutletPicker({ mandatory = false } = {}) {
  const outlets = state.storeOutlets || []
  const html = outlets.map(o => `
    <div class="customer-row" data-pick-outlet-id="${escapeHtml(o.id)}" data-pick-outlet-name="${escapeHtml(o.name)}">
      <span class="cust-id">${escapeHtml(o.name)}</span>
      ${o.id === state.selectedOutletId ? '<span class="cust-pts">current</span>' : ''}
    </div>
  `).join('')

  $('outletPickerList').innerHTML = html || '<div class="empty">No outlets found</div>'

  // Hide close button when selection is mandatory (no outlet chosen yet)
  const closeBtn = $('outletPickerClose')
  if (closeBtn) closeBtn.style.display = mandatory ? 'none' : ''

  $('outletPicker').classList.add('open')
}

function bindOutletPickerEvents() {
  $('outletPickerClose')?.addEventListener('click', () => $('outletPicker').classList.remove('open'))

  $('outletPicker')?.addEventListener('click', e => {
    // Backdrop click — only close if not mandatory (close button is visible)
    if (e.target === $('outletPicker')) {
      if ($('outletPickerClose')?.style.display !== 'none') {
        $('outletPicker').classList.remove('open')
      }
      return
    }
    const outletRow = e.target.closest('[data-pick-outlet-id]')
    if (!outletRow) return

    saveSelectedOutlet(outletRow.dataset.pickOutletId, outletRow.dataset.pickOutletName)
    $('outletPicker').classList.remove('open')
    applyContext()
    renderCustomers()
  })
}

// ── Load store ────────────────────────────────────────────────────────────────

async function loadStore(storeId) {
  const token = ++loadToken
  const [
    { error: membersError },
    { data: rules, error: rulesError },
    { data: cap },
    { data: outlets },
  ] = await Promise.all([
    loadMembers(storeId),
    loadRewardRules(storeId),
    getStoreBonusCap(storeId),
    loadStoreOutlets(storeId),
  ])
  if (token !== loadToken) return
  if (membersError || rulesError) throw membersError || rulesError

  state.rewardRules  = rules   || []
  state.bonusCap     = cap
  state.storeOutlets = outlets || []

  // Validate persisted outlet still belongs to this store
  if (state.selectedOutletId) {
    const stillValid = state.storeOutlets.some(o => o.id === state.selectedOutletId)
    if (!stillValid) clearSelectedOutlet()
  }

  // Outlet selection gate — only when the store has outlets configured
  if (state.storeOutlets.length > 0 && !state.selectedOutletId) {
    if (state.storeOutlets.length === 1) {
      // Auto-select the only outlet — no picker needed
      saveSelectedOutlet(state.storeOutlets[0].id, state.storeOutlets[0].name)
    } else {
      // Show the store name while staff pick their outlet
      applyContext()
      openOutletPicker({ mandatory: true })
      return  // Do not render member list until outlet is chosen
    }
  }

  applyContext()
  renderCustomers()
}

// ── Boot ──────────────────────────────────────────────────────────────────────

async function boot() {
  $('backBtn')?.addEventListener('click', openStorePicker)
  $('changeOutletBtn')?.addEventListener('click', () => openOutletPicker({ mandatory: false }))
  bindStorePickerEvents()
  bindOutletPickerEvents()
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

  try {
    const user = await initAuth()
    if (!user) return

    loadSelectedStore()
    loadSelectedOutlet()

    const [{ data: profile }] = await Promise.all([
      loadUserProfile(user.id),
      loadStaffStores(user.id),
      loadManagedStores().then(({ data }) => { managedStores = data || [] }),
    ])
    $('staffId').textContent = toHumanId(profile?.public_id, user.id)

    if (!state.selectedStoreId) {
      const stores = state.staffStores || []
      if (!stores.length) {
        $('customerList').innerHTML = '<div class="empty">You are not assigned to any stores. Contact your manager to get access.</div>'
        return
      }
      saveSelectedStore(stores[0].store_id, stores[0].stores?.name || '')
    }

    await loadStore(state.selectedStoreId)
  } catch (err) {
    captureError(err)
    alert('Something went wrong loading the page.')
  }
}

boot()
