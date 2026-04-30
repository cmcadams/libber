import { captureError } from '../../lib/sentry.js'
import { initAuth } from '../../services/auth.js'
import { loadManagedStores } from '../../services/applicants.js'
import { loadUserProfile } from '../../services/members.js'
import { loadStaffStores } from '../../services/staff.js'
import { saveSelectedStore } from '../../lib/storage.js'
import { escapeHtml } from '../../lib/escape.js'
import { state } from '../../state/state.js'
import { $ } from '../../lib/dom.js'
import { toHumanId } from '../../lib/format.js'

if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('/apps/staff/sw.js').catch(() => {})
}

async function init() {
  try {
    const user = await initAuth()
    const { data: profile } = user?.id ? await loadUserProfile(user.id) : { data: null }
    $('myId').textContent = toHumanId(profile?.public_id, user?.id)
    if (user?.id) {
      const [{ error: storesError }, { data: managedStores }] = await Promise.all([
        loadStaffStores(user.id),
        loadManagedStores()
      ])
      if (storesError) throw storesError
      if (managedStores?.length) $('managerBtn').style.display = ''
    }
    renderStaffStores()
    bindEvents()
  } catch (err) {
    captureError(err)
  }
}

function renderStaffStores() {
  const list    = $('staffStoreList')
  const section = $('staffStoresSection')
  const stores  = state.staffStores || []

  if (!stores.length) {
    section.style.display = 'none'
    return
  }

  section.style.display = ''
  list.innerHTML = stores.map(store => `
    <button class="store-card" data-open-store-id="${escapeHtml(store.store_id)}" data-open-store-name="${escapeHtml(store.stores?.name || 'Store')}">
      <span class="store-name">${escapeHtml(store.stores?.name || 'Untitled store')}</span>
    </button>
  `).join('')
}

function bindEvents() {
  $('staffStoreList')?.addEventListener('click', event => {
    const button = event.target.closest('[data-open-store-id]')
    if (!button) return
    saveSelectedStore(button.dataset.openStoreId, button.dataset.openStoreName)
    window.location.href = '/apps/staff/page.html'
  })

  $('managerBtn')?.addEventListener('click', () => { window.location.href = '/apps/staff/manager.html' })
  $('refreshBtn')?.addEventListener('click', handleRefresh)
}

async function handleRefresh() {
  const btn = $('refreshBtn')
  btn.classList.add('loading')
  try {
    const [{ error: storesError }, { data: managedStores }] = await Promise.all([
      loadStaffStores(state.user?.id),
      loadManagedStores()
    ])
    if (storesError) throw storesError
    $('managerBtn').style.display = managedStores?.length ? '' : 'none'
    renderStaffStores()
  } catch (err) {
    captureError(err)
  } finally {
    btn.classList.remove('loading')
  }
}

init()
