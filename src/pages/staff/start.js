import { captureError } from '../../lib/sentry.js'
import { initAuth } from '../../services/auth.js'
import { getStores } from '../../services/stores.js'
import { applyForStaff, loadMyApplications, loadManagedStores } from '../../services/applicants.js'
import { loadUserProfile } from '../../services/members.js'
import { loadStaffStores } from '../../services/staff.js'
import { saveSelectedStore } from '../../lib/storage.js'
import { escapeHtml } from '../../lib/escape.js'
import { state } from '../../state/state.js'
import { $, $$ } from '../../lib/dom.js'
import { toHumanId } from '../../lib/format.js'

let selectedStoreId = null
let isPendingForSelectedStore = false
let pendingStoreIds = new Set()

async function init() {
  try {
    const user = await initAuth()
    const { data: profile } = user?.id ? await loadUserProfile(user.id) : { data: null }
    $('myId').textContent = toHumanId(profile?.public_id, user?.id)
    if (user?.id) {
      const [{ error: storesError }, { data: applications }, { data: managedStores }] = await Promise.all([
        loadStaffStores(user.id),
        loadMyApplications(user.id),
        loadManagedStores()
      ])
      if (storesError) throw storesError
      pendingStoreIds = new Set((applications ?? []).map(a => a.store_id))
      if (managedStores?.length) $('managerLink').style.display = ''
    }
    renderStaffStores()
    await renderApplyStores()
    bindEvents()
    updateApplyButton()
  } catch (err) {
    captureError(err)
    setStatus(err.message || 'Could not load page.', true)
  }
}

function renderStaffStores() {
  const list = $('staffStoreList')
  const section = $('staffStoresSection')
  const stores = state.staffStores || []

  if (!stores.length) {
    section.style.display = 'none'
    return
  }

  section.style.display = ''
  list.innerHTML = stores.map(store => `
    <button class="pick-card" data-open-store-id="${escapeHtml(store.store_id)}" data-open-store-name="${escapeHtml(store.stores?.name || 'Store')}">
      <span class="pick-title">${escapeHtml(store.stores?.name || 'Untitled store')}</span>
      <span class="pick-sub">${escapeHtml(store.store_id)}</span>
    </button>
  `).join('')
}

async function renderApplyStores() {
  const list = $('storeList')
  const { data, error } = await getStores()

  if (error) throw error

  if (!data?.length) {
    list.innerHTML = '<p class="empty">No stores found</p>'
    return
  }

  list.innerHTML = data.map(store => `
    <button class="pick-card" data-store-id="${escapeHtml(store.id)}">
      <span class="pick-title">${escapeHtml(store.name || 'Untitled store')}</span>
      <span class="pick-sub">${escapeHtml(store.id)}</span>
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

  $('storeList')?.addEventListener('click', event => {
    const button = event.target.closest('[data-store-id]')
    if (!button) return

    selectedStoreId = button.dataset.storeId
    isPendingForSelectedStore = pendingStoreIds.has(selectedStoreId)
    $$('[data-store-id]').forEach(node => {
      node.classList.toggle('selected', node === button)
    })
    $('selectedStore').textContent = button.querySelector('.pick-title')?.textContent || selectedStoreId
    setStatus('')
    updateApplyButton()
  })

  $('applyBtn')?.addEventListener('click', handleApply)
  $('refreshBtn')?.addEventListener('click', handleRefresh)
}

async function handleRefresh() {
  const btn = $('refreshBtn')
  btn.classList.add('loading')
  try {
    const [{ error: storesError }, { data: applications }, { data: managedStores }] = await Promise.all([
      loadStaffStores(state.user?.id),
      loadMyApplications(state.user?.id),
      loadManagedStores()
    ])
    if (storesError) throw storesError
    pendingStoreIds = new Set((applications ?? []).map(a => a.store_id))
    $('managerLink').style.display = managedStores?.length ? '' : 'none'
    renderStaffStores()
  } catch (err) {
    captureError(err)
    setStatus(err.message || 'Could not refresh.', true)
  } finally {
    btn.classList.remove('loading')
  }
}

async function handleApply() {
  if (!selectedStoreId) return

  const button = $('applyBtn')
  button.disabled = true
  button.textContent = 'Applying...'

  try {
    const { error } = await applyForStaff(selectedStoreId)
    if (error) throw error

    pendingStoreIds.add(selectedStoreId)
    isPendingForSelectedStore = true
    updateApplyButton()
    setStatus('Applied. Ask the manager to approve you on their screen.')
  } catch (err) {
    captureError(err)
    setStatus(err.message || 'Could not apply.', true)
    updateApplyButton()
  }
}

function updateApplyButton() {
  const button = $('applyBtn')
  if (!button) return

  if (!selectedStoreId) {
    button.textContent = 'Apply for staff'
    button.disabled = true
    return
  }

  if (isPendingForSelectedStore) {
    button.textContent = 'Pending approval'
    button.disabled = true
    setStatus('Your application is waiting for manager approval.')
    return
  }

  button.textContent = 'Apply for staff'
  button.disabled = false
}

function setStatus(message, isError = false) {
  const status = $('status')
  if (!status) return

  status.textContent = message
  status.classList.toggle('error', isError)
}

init()
