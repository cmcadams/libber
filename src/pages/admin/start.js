import { initAuth } from '../../services/auth.js'
import { assignManager, loadAdminUsers, loadAllStores } from '../../services/admin.js'

let selectedUserId = null
let selectedStoreId = null

const $ = id => document.getElementById(id)

async function init() {
  try {
    await initAuth()
    await Promise.all([renderUsers(), renderStores()])
    bindEvents()
    updateAssignButton()
  } catch (err) {
    console.error(err)
    setStatus(err.message || 'Could not load admin tools.', true)
  }
}

async function renderUsers() {
  const list = $('userList')
  const { data, error } = await loadAdminUsers()

  if (error) throw error

  if (!data?.length) {
    list.innerHTML = '<p class="empty">No users found</p>'
    return
  }

  list.innerHTML = data.map(user => `
    <button class="pick-card" data-user-id="${user.user_id}">
      <span class="pick-title">${user.public_id || 'No public ID'}</span>
      <span class="pick-sub">${user.user_id}</span>
    </button>
  `).join('')
}

async function renderStores() {
  const list = $('storeList')
  const { data, error } = await loadAllStores()

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
  $('userList')?.addEventListener('click', event => {
    const button = event.target.closest('[data-user-id]')
    if (!button) return

    selectedUserId = button.dataset.userId
    document.querySelectorAll('[data-user-id]').forEach(node => {
      node.classList.toggle('selected', node === button)
    })
    $('selectedUser').textContent = button.querySelector('.pick-title')?.textContent || selectedUserId
    updateAssignButton()
  })

  $('storeList')?.addEventListener('click', event => {
    const button = event.target.closest('[data-store-id]')
    if (!button) return

    selectedStoreId = button.dataset.storeId
    document.querySelectorAll('[data-store-id]').forEach(node => {
      node.classList.toggle('selected', node === button)
    })
    $('selectedStore').textContent = button.querySelector('.pick-title')?.textContent || selectedStoreId
    updateAssignButton()
  })

  $('assignBtn')?.addEventListener('click', handleAssign)
}

async function handleAssign() {
  if (!selectedUserId || !selectedStoreId) return

  const button = $('assignBtn')
  button.disabled = true
  button.textContent = 'Assigning...'

  try {
    const { error } = await assignManager(selectedUserId, selectedStoreId)
    if (error) throw error

    setStatus('Manager assigned.')
    button.textContent = 'Assigned'
    setTimeout(() => {
      button.textContent = 'Assign manager'
      updateAssignButton()
    }, 1200)
  } catch (err) {
    console.error(err)
    setStatus(err.message || 'Could not assign manager.', true)
    button.textContent = 'Assign manager'
    updateAssignButton()
  }
}

function updateAssignButton() {
  const button = $('assignBtn')
  if (!button) return

  button.disabled = !(selectedUserId && selectedStoreId)
}

function setStatus(message, isError = false) {
  const status = $('status')
  if (!status) return

  status.textContent = message
  status.classList.toggle('error', isError)
}

init()
