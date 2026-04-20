import { initAuth } from '../../services/auth.js'
import { assignManager, loadAdminUsers, loadAllStores, createStore, loadRewardRules, insertRewardRule, deleteRewardRule, updateRewardRuleOrder } from '../../services/admin.js'

let selectedUserId = null
let selectedStoreId = null
let currentRules = []

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
    const storeName = button.querySelector('.pick-title')?.textContent || selectedStoreId
    $('selectedStore').textContent = storeName
    updateAssignButton()
    loadAndRenderRules(selectedStoreId, storeName)
  })

  $('createStoreBtn')?.addEventListener('click', handleCreateStore)
  $('assignBtn')?.addEventListener('click', handleAssign)

  $('addRuleBtn')?.addEventListener('click', handleAddRule)

  $('rulesList')?.addEventListener('click', async event => {
    if (!selectedStoreId) return

    const deleteBtn = event.target.closest('[data-delete-rule-id]')
    if (deleteBtn) {
      deleteBtn.disabled = true
      const { error } = await deleteRewardRule(deleteBtn.dataset.deleteRuleId)
      if (error) { deleteBtn.disabled = false; return }
      loadAndRenderRules(selectedStoreId, $('rulesStoreName').textContent)
      return
    }

    const moveBtn = event.target.closest('[data-move-rule-id]')
    if (moveBtn) {
      await handleMoveRule(moveBtn.dataset.moveRuleId, moveBtn.dataset.direction)
    }
  })
}

async function handleCreateStore() {
  const name = $('newStoreName').value.trim()
  if (!name) return

  $('createStoreBtn').disabled = true
  $('createStoreStatus').textContent = ''

  const { data, error } = await createStore(name)
  $('createStoreBtn').disabled = false

  if (error) {
    $('createStoreStatus').textContent = error.message || 'Could not create store.'
    return
  }

  $('newStoreName').value = ''
  $('createStoreStatus').textContent = `Store "${data.name}" created.`
  await renderStores()
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

function renderRulesList() {
  if (!currentRules.length) {
    $('rulesList').innerHTML = '<p class="empty">No rules yet. Add one below.</p>'
    return
  }

  $('rulesList').innerHTML = currentRules.map((r, i) => `
    <div class="rule-row">
      <div class="rule-order-btns">
        <button class="rule-order-btn" data-move-rule-id="${r.id}" data-direction="up" ${i === 0 ? 'disabled' : ''}>↑</button>
        <button class="rule-order-btn" data-move-rule-id="${r.id}" data-direction="down" ${i === currentRules.length - 1 ? 'disabled' : ''}>↓</button>
      </div>
      <span class="rule-badge">${r.kind}</span>
      <span class="rule-label-text">${r.label || '—'}</span>
      <span class="rule-pts-text">+${r.points} pts</span>
      <button class="rule-delete-btn" data-delete-rule-id="${r.id}">Remove</button>
    </div>
  `).join('')
}

async function loadAndRenderRules(storeId, storeName) {
  $('rulesPanel').style.display = 'block'
  $('rulesStoreName').textContent = storeName
  $('rulesList').innerHTML = '<p class="empty">Loading rules...</p>'

  const { data, error } = await loadRewardRules(storeId)
  if (error) {
    $('rulesList').innerHTML = '<p class="empty">Could not load rules.</p>'
    return
  }

  currentRules = data || []
  renderRulesList()
}

async function handleMoveRule(ruleId, direction) {
  const idx = currentRules.findIndex(r => r.id === ruleId)
  if (idx === -1) return

  const swapIdx = direction === 'up' ? idx - 1 : idx + 1
  if (swapIdx < 0 || swapIdx >= currentRules.length) return

  // swap in array
  ;[currentRules[idx], currentRules[swapIdx]] = [currentRules[swapIdx], currentRules[idx]]

  // normalize sort_orders to 1, 2, 3...
  currentRules.forEach((r, i) => { r.sort_order = i + 1 })

  // re-render immediately so UI feels instant
  renderRulesList()

  // persist the two affected rules sequentially to avoid conflicts
  await updateRewardRuleOrder(currentRules[idx].id, currentRules[idx].sort_order)
  await updateRewardRuleOrder(currentRules[swapIdx].id, currentRules[swapIdx].sort_order)
}

async function handleAddRule() {
  const label = $('ruleLabel').value.trim()
  const points = parseInt($('rulePoints').value)
  const kind = $('ruleKind').value

  if (!points || points < 1) {
    $('addRuleStatus').textContent = 'Enter a valid point value.'
    return
  }
  if (kind === 'award' && !label) {
    $('addRuleStatus').textContent = 'Award rules need a label.'
    return
  }

  $('addRuleBtn').disabled = true
  $('addRuleStatus').textContent = ''

  const { error } = await insertRewardRule(selectedStoreId, { label, points, kind }, currentRules.length + 1)
  $('addRuleBtn').disabled = false

  if (error) {
    $('addRuleStatus').textContent = error.message || 'Could not add rule.'
    return
  }

  $('ruleLabel').value = ''
  $('rulePoints').value = ''
  loadAndRenderRules(selectedStoreId, $('rulesStoreName').textContent)
}

function setStatus(message, isError = false) {
  const status = $('status')
  if (!status) return

  status.textContent = message
  status.classList.toggle('error', isError)
}

init()
