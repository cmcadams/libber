import { initAuth } from '../../services/auth.js'
import { getStores } from '../../services/stores.js'
import { applyForStaff } from '../../services/applicants.js'
import { loadUserProfile } from '../../services/members.js'
import { loadStaffStores } from '../../services/staff.js'
import { saveSelectedStore } from '../../lib/storage.js'
import { state } from '../../state/state.js'

let selectedStoreId = null
let selectedStoreName = null
let isApprovedForSelectedStore = false

const $ = id => document.getElementById(id)
const toHumanId = (publicId, userId) => publicId || `USR-${String(userId || '').slice(0, 6).toUpperCase()}`

async function init() {
  try {
    const user = await initAuth()
    const profile = user?.id ? await loadUserProfile(user.id) : null
    $('myId').textContent = toHumanId(profile?.public_id, user?.id)
    if (user?.id) {
      await loadStaffStores(user.id)
    }
    await renderStores()
    bindEvents()
    updateActionButton()
  } catch (err) {
    console.error(err)
    setStatus(err.message || 'Could not load staff apply page.', true)
  }
}

async function renderStores() {
  const list = $('storeList')
  const { data, error } = await getStores()

  if (error) throw error

  if (!data?.length) {
    list.innerHTML = '<p class="empty">No stores found</p>'
    return
  }

  list.innerHTML = data.map(store => `
    <button class="pick-card" data-store-id="${store.id}">
      <span class="pick-title">${store.name || 'Untitled store'}</span>
      <span class="pick-sub">${store.id}</span>
    </button>
  `).join('')
}

function bindEvents() {
  $('storeList')?.addEventListener('click', event => {
    const button = event.target.closest('[data-store-id]')
    if (!button) return

    selectedStoreId = button.dataset.storeId
    selectedStoreName = button.querySelector('.pick-title')?.textContent || 'Store'
    isApprovedForSelectedStore = (state.staffStores || []).some(store => store.store_id === selectedStoreId)
    document.querySelectorAll('[data-store-id]').forEach(node => {
      node.classList.toggle('selected', node === button)
    })
    $('selectedStore').textContent = button.querySelector('.pick-title')?.textContent || selectedStoreId
    setStatus('')
    updateActionButton()
  })

  $('applyBtn')?.addEventListener('click', handlePrimaryAction)
}

async function handlePrimaryAction() {
  if (isApprovedForSelectedStore) {
    saveSelectedStore(selectedStoreId, selectedStoreName || 'Store')
    window.location.href = '/staffpage.html'
    return
  }

  await handleApply()
}

async function handleApply() {
  if (!selectedStoreId) return

  const button = $('applyBtn')
  button.disabled = true
  button.textContent = 'Applying...'

  try {
    const { error } = await applyForStaff(selectedStoreId)
    if (error) throw error

    setStatus('Applied. Ask the manager to approve you on their screen.')
    button.textContent = 'Applied'
  } catch (err) {
    console.error(err)
    setStatus(err.message || 'Could not apply.', true)
    button.textContent = 'Apply for staff'
    updateApplyButton()
  }
}

function updateApplyButton() {
  const button = $('applyBtn')
  if (!button) return

  button.disabled = !selectedStoreId
}

function updateActionButton() {
  const button = $('applyBtn')
  if (!button) return

  if (!selectedStoreId) {
    button.textContent = 'Apply for staff'
    updateApplyButton()
    return
  }

  if (isApprovedForSelectedStore) {
    button.textContent = 'Open staff tools'
    button.disabled = false
    setStatus('You are approved for this store. Open staff tools to continue.')
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
