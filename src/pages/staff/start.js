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
import { initCog } from '../../lib/cog.js'

if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('/apps/staff/sw.js').catch(() => {})
}

initCog()

let selectedStoreId           = null
let isPendingForSelectedStore = false
let pendingStoreIds           = new Set()

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
      const staffStoreIds = new Set((state.staffStores || []).map(s => s.store_id))
      pendingStoreIds = new Set((applications ?? []).filter(a => !staffStoreIds.has(a.store_id)).map(a => a.store_id))
      if (managedStores?.length) $('managerSection').style.display = ''
    }
    renderStaffStores()
    await renderApplyStores()
    bindEvents()
    updateApplyButton()
  } catch (err) {
    captureError(err)
    $('applyAction').style.display = ''
    setStatus(err.message || 'Could not load page.', true)
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
    <button class="pick-card" data-open-store-id="${escapeHtml(store.store_id)}" data-open-store-name="${escapeHtml(store.stores?.name || 'Store')}">
      <span class="pick-title">${escapeHtml(store.stores?.name || 'Untitled store')}</span>
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

  list.innerHTML = data.map(store => {
    const pending = pendingStoreIds.has(store.id)
    return `
      <button class="pick-card${pending ? ' pending' : ''}" data-store-id="${escapeHtml(store.id)}">
        <span class="pick-title">${escapeHtml(store.name || 'Untitled store')}</span>
        ${pending ? '<span class="pending-badge">Pending</span>' : ''}
      </button>`
  }).join('')
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
    setStatus('')
    updateApplyButton()
  })

  $('managerBtn')?.addEventListener('click', () => { window.location.href = '/apps/staff/manager.html' })
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
    const staffStoreIds = new Set((state.staffStores || []).map(s => s.store_id))
    pendingStoreIds = new Set((applications ?? []).filter(a => !staffStoreIds.has(a.store_id)).map(a => a.store_id))
    $('managerSection').style.display = managedStores?.length ? '' : 'none'
    renderStaffStores()
    $$('[data-store-id]').forEach(card => {
      const isPending = pendingStoreIds.has(card.dataset.storeId)
      card.classList.toggle('pending', isPending)
      const badge = card.querySelector('.pending-badge')
      if (isPending && !badge) {
        card.insertAdjacentHTML('beforeend', '<span class="pending-badge">Pending</span>')
      } else if (!isPending && badge) {
        badge.remove()
      }
    })
    if (selectedStoreId) {
      isPendingForSelectedStore = pendingStoreIds.has(selectedStoreId)
      updateApplyButton()
    }
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
  button.disabled    = true
  button.textContent = 'Applying...'

  try {
    const { error } = await applyForStaff(selectedStoreId)
    if (error) throw error
    pendingStoreIds.add(selectedStoreId)
    isPendingForSelectedStore = true
    $$('[data-store-id]').forEach(card => {
      if (card.dataset.storeId !== selectedStoreId) return
      card.classList.add('pending')
      if (!card.querySelector('.pending-badge')) {
        card.insertAdjacentHTML('beforeend', '<span class="pending-badge">Pending</span>')
      }
    })
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
  const action = $('applyAction')
  if (!button) return

  if (!selectedStoreId) {
    if (action) action.style.display = 'none'
    return
  }

  if (action) action.style.display = ''

  if (isPendingForSelectedStore) {
    button.textContent = 'Pending approval'
    button.disabled    = true
    setStatus('Your application is waiting for manager approval.')
    return
  }

  button.textContent = 'Apply for staff'
  button.disabled    = false
}

function setStatus(message, isError = false) {
  const status = $('status')
  if (!status) return
  status.textContent = message
  status.classList.toggle('error', isError)
}

init()
