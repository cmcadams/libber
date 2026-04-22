import { initAuth } from '../../services/auth.js'
import {
  assignManager,
  loadAdminUsers, loadAllStores,
  createStore, updateStoreName, removeStore,
  loadRewardRules, insertRewardRule, deleteRewardRule, updateRewardRuleOrder,
  loadStoreManagers, removeManager,
  loadStoreStaff, removeStaffAdmin,
  loadStoreApplicants, loadAllApplicants, approveApplicantAdmin, rejectApplicant
} from '../../services/admin.js'
import { escapeHtml } from '../../lib/escape.js'

const $ = id => document.getElementById(id)

let users = []
let stores = []
let currentRules = []

let selectedManagerStoreId = null
let selectedStaffStoreId = null
let selectedRulesStoreId = null
let selectedManageStoreId = null
let selectedManageStoreName = null

async function init() {
  try {
    await initAuth()
    const [{ data: u, error: ue }, { data: s, error: se }] = await Promise.all([
      loadAdminUsers(),
      loadAllStores()
    ])
    if (ue) throw ue
    if (se) throw se

    users = u || []
    stores = s || []

    renderPicker('managerStoreList', stores, 'store')
    renderPicker('staffStoreList', stores, 'store')
    renderPicker('rulesStoreList', stores, 'store')
    renderPicker('manageStoreList', stores, 'store')
    renderAllStores()
    renderAllUsers()

    bindEvents()
  } catch (err) {
    console.error(err)
  }
}

// ── Pickers ──────────────────────────────────────────────────────────────────

function renderPicker(containerId, items, type) {
  const el = $(containerId)
  if (!el) return

  if (!items.length) {
    el.innerHTML = '<p class="empty">None found</p>'
    return
  }

  if (type === 'user') {
    el.innerHTML = items.map(u => `
      <button class="pick-card" data-user-id="${escapeHtml(u.user_id)}">
        <span class="pick-title">${escapeHtml(u.public_id || 'No public ID')}</span>
        <span class="pick-sub">${escapeHtml(u.user_id)}</span>
      </button>
    `).join('')
  } else {
    el.innerHTML = items.map(s => `
      <button class="pick-card" data-store-id="${escapeHtml(s.id)}" data-store-name="${escapeHtml(s.name || 'Untitled')}">
        <span class="pick-title">${escapeHtml(s.name || 'Untitled store')}</span>
        <span class="pick-sub">${escapeHtml(s.id)}</span>
      </button>
    `).join('')
  }
}

// ── Directory lists ───────────────────────────────────────────────────────────

function renderAllStores() {
  const el = $('allStoresList')
  if (!el) return
  if (!stores.length) { el.innerHTML = '<p class="empty">No stores yet.</p>'; return }
  el.innerHTML = stores.map(s => `
    <div class="dir-row" data-store-id="${escapeHtml(s.id)}">
      <div class="dir-info">
        <span class="dir-name">${escapeHtml(s.name || 'Untitled')}</span>
        <span class="dir-sub">${escapeHtml(s.id)}</span>
      </div>
      <div class="dir-actions">
        <button class="btn-sm" data-edit-store-id="${escapeHtml(s.id)}" data-store-name="${escapeHtml(s.name || '')}">Edit</button>
        <button class="btn-danger-sm" data-remove-store-id="${escapeHtml(s.id)}">Remove</button>
      </div>
    </div>
  `).join('')
}

function renderAllUsers() {
  const el = $('allUsersList')
  if (!el) return
  if (!users.length) { el.innerHTML = '<p class="empty">No users yet.</p>'; return }
  el.innerHTML = users.map(u => `
    <div class="dir-row">
      <div class="dir-info">
        <span class="dir-name">${escapeHtml(u.public_id || 'No public ID')}</span>
        <span class="dir-sub">${escapeHtml(u.user_id)}</span>
      </div>
    </div>
  `).join('')
}

function resolvePublicId(userId) {
  const u = users.find(u => u.user_id === userId)
  return u ? (u.public_id || userId) : userId
}

function renderMemberList(containerId, members, removeAttr) {
  const el = $(containerId)
  if (!el) return
  if (!members.length) { el.innerHTML = '<p class="empty">None.</p>'; return }
  el.innerHTML = members.map(m => `
    <div class="dir-row">
      <div class="dir-info">
        <span class="dir-name">${escapeHtml(resolvePublicId(m.user_id))}</span>
        <span class="dir-sub">${escapeHtml(m.user_id)}</span>
      </div>
      <div class="dir-actions">
        <button class="btn-danger-sm" ${removeAttr}="${escapeHtml(m.user_id)}">Remove</button>
      </div>
    </div>
  `).join('')
}

// ── Events ────────────────────────────────────────────────────────────────────

function bindEvents() {
  document.querySelectorAll('.action-btn[data-section]').forEach(btn => {
    btn.addEventListener('click', () => {
      showSection(btn.dataset.section, btn)
      if (btn.dataset.section === 'applicants') loadAndRenderApplicants()
    })
  })

  // Assign manager — store picker
  $('managerStoreList')?.addEventListener('click', async e => {
    const btn = e.target.closest('[data-store-id]')
    if (!btn) return
    selectedManagerStoreId = btn.dataset.storeId
    selectInPicker('managerStoreList', btn)
    setStatus('assignManagerStatus', '')
    await loadAndRenderManagerCandidates(btn.dataset.storeId)
  })

  // Assign manager — candidate actions
  $('managerCandidatesList')?.addEventListener('click', async e => {
    const btn = e.target.closest('[data-make-manager-id]')
    if (!btn) return
    btn.disabled = true
    const userId = btn.dataset.makeManagerId
    const { error } = await assignManager(userId, selectedManagerStoreId)
    if (error) { btn.disabled = false; setStatus('assignManagerStatus', error.message || 'Could not assign.', true); return }
    await rejectApplicant(userId, selectedManagerStoreId)
    setStatus('assignManagerStatus', 'Manager assigned.')
    await loadAndRenderManagerCandidates(selectedManagerStoreId)
  })

  // Assign staff — store picker
  $('staffStoreList')?.addEventListener('click', async e => {
    const btn = e.target.closest('[data-store-id]')
    if (!btn) return
    selectedStaffStoreId = btn.dataset.storeId
    selectInPicker('staffStoreList', btn)
    setStatus('assignStaffStatus', '')
    await loadAndRenderStaffCandidates(btn.dataset.storeId)
  })

  // Assign staff — candidate actions
  $('staffCandidatesList')?.addEventListener('click', async e => {
    const btn = e.target.closest('[data-make-staff-id]')
    if (!btn) return
    btn.disabled = true
    const userId = btn.dataset.makeStaffId
    const { error } = await approveApplicantAdmin(userId, selectedStaffStoreId)
    if (error) { btn.disabled = false; setStatus('assignStaffStatus', error.message || 'Could not assign.', true); return }
    setStatus('assignStaffStatus', 'Staff assigned.')
    await loadAndRenderStaffCandidates(selectedStaffStoreId)
  })

  // Create store
  $('createStoreBtn')?.addEventListener('click', handleCreateStore)
  $('newStoreName')?.addEventListener('keydown', e => { if (e.key === 'Enter') handleCreateStore() })

  // Reward rules store picker
  $('rulesStoreList')?.addEventListener('click', async e => {
    const btn = e.target.closest('[data-store-id]')
    if (!btn) return
    selectedRulesStoreId = btn.dataset.storeId
    selectInPicker('rulesStoreList', btn)
    await loadAndRenderRules(btn.dataset.storeId, btn.dataset.storeName)
  })

  // Rules list actions
  $('rulesList')?.addEventListener('click', async e => {
    const deleteBtn = e.target.closest('[data-delete-rule-id]')
    if (deleteBtn) {
      deleteBtn.disabled = true
      const { error } = await deleteRewardRule(deleteBtn.dataset.deleteRuleId)
      if (error) { deleteBtn.disabled = false; return }
      await loadAndRenderRules(selectedRulesStoreId, $('rulesStoreName').textContent)
      return
    }
    const moveBtn = e.target.closest('[data-move-rule-id]')
    if (moveBtn) await handleMoveRule(moveBtn.dataset.moveRuleId, moveBtn.dataset.direction)
  })

  $('addRuleBtn')?.addEventListener('click', handleAddRule)

  // All stores: edit + remove
  $('allStoresList')?.addEventListener('click', async e => {
    const editBtn = e.target.closest('[data-edit-store-id]')
    if (editBtn) { showInlineEdit(editBtn.dataset.editStoreId, editBtn.dataset.storeName); return }

    const removeBtn = e.target.closest('[data-remove-store-id]')
    if (removeBtn) { await handleRemoveStore(removeBtn); return }

    const saveBtn = e.target.closest('[data-save-store-id]')
    if (saveBtn) await handleSaveStoreName(saveBtn)

    const cancelBtn = e.target.closest('[data-cancel-store-id]')
    if (cancelBtn) { renderAllStores(); setStatus('allStoresStatus', '') }
  })

  // Manage store picker
  $('manageStoreList')?.addEventListener('click', async e => {
    const btn = e.target.closest('[data-store-id]')
    if (!btn) return
    selectedManageStoreId = btn.dataset.storeId
    selectedManageStoreName = btn.dataset.storeName
    selectInPicker('manageStoreList', btn)
    await loadAndRenderManageStore(btn.dataset.storeId, btn.dataset.storeName)
  })

  // Manage store: remove manager / remove staff
  $('manageManagersList')?.addEventListener('click', async e => {
    const btn = e.target.closest('[data-remove-manager-id]')
    if (!btn) return
    btn.disabled = true
    const { error } = await removeManager(btn.dataset.removeManagerId, selectedManageStoreId)
    if (error) { btn.disabled = false; setStatus('manageStoreStatus', error.message || 'Could not remove.', true); return }
    await loadAndRenderManageStore(selectedManageStoreId, selectedManageStoreName)
  })

  $('manageStaffList')?.addEventListener('click', async e => {
    const btn = e.target.closest('[data-remove-staff-id]')
    if (!btn) return
    btn.disabled = true
    const { error } = await removeStaffAdmin(btn.dataset.removeStaffId, selectedManageStoreId)
    if (error) { btn.disabled = false; setStatus('manageStoreStatus', error.message || 'Could not remove.', true); return }
    await loadAndRenderManageStore(selectedManageStoreId, selectedManageStoreName)
  })

  // Applicants: approve / reject
  $('applicantsList')?.addEventListener('click', async e => {
    const approveBtn = e.target.closest('[data-approve-user-id]')
    if (approveBtn) {
      approveBtn.disabled = true
      const { error } = await approveApplicantAdmin(approveBtn.dataset.approveUserId, approveBtn.dataset.storeId)
      if (error) { approveBtn.disabled = false; setStatus('applicantsStatus', error.message || 'Could not approve.', true); return }
      await loadAndRenderApplicants()
      return
    }
    const rejectBtn = e.target.closest('[data-reject-user-id]')
    if (rejectBtn) {
      rejectBtn.disabled = true
      const { error } = await rejectApplicant(rejectBtn.dataset.rejectUserId, rejectBtn.dataset.storeId)
      if (error) { rejectBtn.disabled = false; setStatus('applicantsStatus', error.message || 'Could not reject.', true); return }
      await loadAndRenderApplicants()
    }
  })
}

// ── Section nav ───────────────────────────────────────────────────────────────

function showSection(name, activeBtn) {
  document.querySelectorAll('#panelArea .panel').forEach(p => p.classList.add('hidden'))
  document.querySelectorAll('.action-btn[data-section]').forEach(b => b.classList.remove('active'))
  const panel = $(`panel-${name}`)
  if (panel) panel.classList.remove('hidden')
  if (activeBtn) activeBtn.classList.add('active')
}

function selectInPicker(containerId, activeBtn) {
  document.querySelectorAll(`#${containerId} .pick-card`).forEach(b => {
    b.classList.toggle('selected', b === activeBtn)
  })
}

// ── Assign manager / staff candidates ─────────────────────────────────────────

async function loadAndRenderManagerCandidates(storeId) {
  const el = $('managerCandidatesList')
  el.innerHTML = '<p class="empty">Loading...</p>'

  const [{ data: managers, error: me }, { data: applicants, error: ae }] = await Promise.all([
    loadStoreManagers(storeId),
    loadStoreApplicants(storeId)
  ])

  if (me || ae) { el.innerHTML = '<p class="empty">Could not load.</p>'; return }

  const managerIds = new Set((managers || []).map(m => m.user_id))
  const pendingRows = (applicants || []).filter(a => !managerIds.has(a.user_id))

  const managerHtml = (managers || []).length
    ? (managers || []).map(m => `
        <div class="dir-row">
          <div class="dir-info">
            <span class="dir-name">${escapeHtml(resolvePublicId(m.user_id))}</span>
            <span class="dir-sub">${escapeHtml(m.user_id)}</span>
          </div>
          <span class="role-badge">Manager</span>
        </div>`).join('')
    : '<p class="empty">No managers yet.</p>'

  const pendingHtml = pendingRows.length
    ? pendingRows.map(a => `
        <div class="dir-row">
          <div class="dir-info">
            <span class="dir-name">${escapeHtml(resolvePublicId(a.user_id))}</span>
            <span class="dir-sub">${escapeHtml(a.user_id)}</span>
          </div>
          <div class="dir-actions">
            <button class="btn-sm" data-make-manager-id="${escapeHtml(a.user_id)}">Make Manager</button>
          </div>
        </div>`).join('')
    : '<p class="empty">No pending applicants.</p>'

  el.innerHTML = `
    <div class="candidate-group-title">Current Managers</div>
    ${managerHtml}
    <div class="candidate-group-title" style="margin-top:12px">Pending Applicants</div>
    ${pendingHtml}
  `
}

async function loadAndRenderStaffCandidates(storeId) {
  const el = $('staffCandidatesList')
  el.innerHTML = '<p class="empty">Loading...</p>'

  const [{ data: staff, error: se }, { data: applicants, error: ae }] = await Promise.all([
    loadStoreStaff(storeId),
    loadStoreApplicants(storeId)
  ])

  if (se || ae) { el.innerHTML = '<p class="empty">Could not load.</p>'; return }

  const staffIds = new Set((staff || []).map(s => s.user_id))
  const pendingRows = (applicants || []).filter(a => !staffIds.has(a.user_id))

  const staffHtml = (staff || []).length
    ? (staff || []).map(s => `
        <div class="dir-row">
          <div class="dir-info">
            <span class="dir-name">${escapeHtml(resolvePublicId(s.user_id))}</span>
            <span class="dir-sub">${escapeHtml(s.user_id)}</span>
          </div>
          <span class="role-badge">Staff</span>
        </div>`).join('')
    : '<p class="empty">No staff yet.</p>'

  const pendingHtml = pendingRows.length
    ? pendingRows.map(a => `
        <div class="dir-row">
          <div class="dir-info">
            <span class="dir-name">${escapeHtml(resolvePublicId(a.user_id))}</span>
            <span class="dir-sub">${escapeHtml(a.user_id)}</span>
          </div>
          <div class="dir-actions">
            <button class="btn-sm" data-make-staff-id="${escapeHtml(a.user_id)}">Make Staff</button>
          </div>
        </div>`).join('')
    : '<p class="empty">No pending applicants.</p>'

  el.innerHTML = `
    <div class="candidate-group-title">Current Staff</div>
    ${staffHtml}
    <div class="candidate-group-title" style="margin-top:12px">Pending Applicants</div>
    ${pendingHtml}
  `
}

// ── Create store ──────────────────────────────────────────────────────────────

async function handleCreateStore() {
  const name = $('newStoreName').value.trim()
  if (!name) return
  const btn = $('createStoreBtn')
  btn.disabled = true
  $('createStoreStatus').textContent = ''

  const { data, error } = await createStore(name)
  btn.disabled = false

  if (error) {
    setStatus('createStoreStatus', error.message || 'Could not create store.', true)
    return
  }

  $('newStoreName').value = ''
  setStatus('createStoreStatus', `"${data.name}" created.`)

  stores = [...stores, { id: data.id, name: data.name }]
  refreshAllStorePickers()
}

function refreshAllStorePickers() {
  renderPicker('managerStoreList', stores, 'store')
  renderPicker('staffStoreList', stores, 'store')
  renderPicker('rulesStoreList', stores, 'store')
  renderPicker('manageStoreList', stores, 'store')
  renderAllStores()

  if (selectedManagerStoreId) {
    const btn = document.querySelector(`#managerStoreList [data-store-id="${CSS.escape(selectedManagerStoreId)}"]`)
    if (btn) btn.classList.add('selected')
  }
  if (selectedStaffStoreId) {
    const btn = document.querySelector(`#staffStoreList [data-store-id="${CSS.escape(selectedStaffStoreId)}"]`)
    if (btn) btn.classList.add('selected')
  }
  if (selectedRulesStoreId) {
    const btn = document.querySelector(`#rulesStoreList [data-store-id="${CSS.escape(selectedRulesStoreId)}"]`)
    if (btn) btn.classList.add('selected')
  }
  if (selectedManageStoreId) {
    const btn = document.querySelector(`#manageStoreList [data-store-id="${CSS.escape(selectedManageStoreId)}"]`)
    if (btn) btn.classList.add('selected')
  }
}

// ── All stores: edit / remove ─────────────────────────────────────────────────

function showInlineEdit(storeId, currentName) {
  const row = $('allStoresList').querySelector(`[data-store-id="${CSS.escape(storeId)}"]`)
  if (!row) return
  row.outerHTML = `
    <div class="inline-edit-row" data-store-id="${escapeHtml(storeId)}">
      <input class="input input-grow" value="${escapeHtml(currentName)}" id="edit-input-${escapeHtml(storeId)}" />
      <button class="btn-sm" data-save-store-id="${escapeHtml(storeId)}">Save</button>
      <button class="btn-danger-sm" data-cancel-store-id="${escapeHtml(storeId)}">Cancel</button>
    </div>
  `
  $(`edit-input-${storeId}`)?.focus()
}

async function handleSaveStoreName(saveBtn) {
  const storeId = saveBtn.dataset.saveStoreId
  const input = $(`edit-input-${storeId}`)
  const name = input?.value.trim()
  if (!name) return

  saveBtn.disabled = true
  const { data, error } = await updateStoreName(storeId, name)
  saveBtn.disabled = false

  if (error) {
    setStatus('allStoresStatus', error.message || 'Could not update name.', true)
    return
  }

  stores = stores.map(s => s.id === storeId ? { ...s, name: data.name } : s)
  if (selectedManageStoreId === storeId) {
    selectedManageStoreName = data.name
    $('manageStoreName').textContent = data.name
  }
  refreshAllStorePickers()
  setStatus('allStoresStatus', 'Store name updated.')
}

async function handleRemoveStore(removeBtn) {
  const storeId = removeBtn.dataset.removeStoreId

  if (removeBtn.dataset.confirm !== 'true') {
    removeBtn.dataset.confirm = 'true'
    removeBtn.textContent = 'Sure?'
    setTimeout(() => {
      if (removeBtn.dataset.confirm === 'true') {
        removeBtn.dataset.confirm = ''
        removeBtn.textContent = 'Remove'
      }
    }, 3000)
    return
  }

  removeBtn.disabled = true
  const { error } = await removeStore(storeId)
  if (error) {
    removeBtn.disabled = false
    setStatus('allStoresStatus', error.message || 'Could not remove store.', true)
    return
  }

  stores = stores.filter(s => s.id !== storeId)

  if (selectedManagerStoreId === storeId) {
    selectedManagerStoreId = null
    $('managerCandidatesList').innerHTML = '<p class="empty">Select a store</p>'
  }
  if (selectedStaffStoreId === storeId) {
    selectedStaffStoreId = null
    $('staffCandidatesList').innerHTML = '<p class="empty">Select a store</p>'
  }
  if (selectedRulesStoreId === storeId) {
    selectedRulesStoreId = null
    $('rulesContent').classList.add('hidden')
  }
  if (selectedManageStoreId === storeId) {
    selectedManageStoreId = null
    selectedManageStoreName = null
    $('manageStoreContent').classList.add('hidden')
  }

  renderAllStores()
  refreshAllStorePickers()
  setStatus('allStoresStatus', 'Store removed.')
}

// ── Reward rules ──────────────────────────────────────────────────────────────

async function loadAndRenderRules(storeId, storeName) {
  $('rulesStoreName').textContent = storeName
  $('rulesContent').classList.remove('hidden')
  $('rulesList').innerHTML = '<p class="empty">Loading...</p>'

  const { data, error } = await loadRewardRules(storeId)
  if (error) {
    $('rulesList').innerHTML = '<p class="empty">Could not load rules.</p>'
    return
  }

  currentRules = data || []
  renderRulesList()
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
      <span class="rule-badge">${escapeHtml(r.kind)}</span>
      <span class="rule-label-text">${escapeHtml(r.label || '—')}</span>
      <span class="rule-pts-text">+${r.points} pts</span>
      <button class="rule-delete-btn" data-delete-rule-id="${r.id}">Remove</button>
    </div>
  `).join('')
}

async function handleMoveRule(ruleId, direction) {
  const idx = currentRules.findIndex(r => r.id === ruleId)
  if (idx === -1) return
  const swapIdx = direction === 'up' ? idx - 1 : idx + 1
  if (swapIdx < 0 || swapIdx >= currentRules.length) return

  ;[currentRules[idx], currentRules[swapIdx]] = [currentRules[swapIdx], currentRules[idx]]
  currentRules.forEach((r, i) => { r.sort_order = i + 1 })
  renderRulesList()

  await Promise.all([
    updateRewardRuleOrder(currentRules[idx].id, currentRules[idx].sort_order),
    updateRewardRuleOrder(currentRules[swapIdx].id, currentRules[swapIdx].sort_order)
  ])
}

async function handleAddRule() {
  const label = $('ruleLabel').value.trim()
  const points = parseInt($('rulePoints').value, 10)
  const kind = $('ruleKind').value

  if (!points || points < 1) { setStatus('addRuleStatus', 'Enter a valid point value.', true); return }
  if (kind === 'award' && !label) { setStatus('addRuleStatus', 'Award rules need a label.', true); return }

  const btn = $('addRuleBtn')
  btn.disabled = true
  $('addRuleStatus').textContent = ''

  const { error } = await insertRewardRule(selectedRulesStoreId, { label, points, kind }, currentRules.length + 1)

  if (error) {
    btn.disabled = false
    setStatus('addRuleStatus', error.message || 'Could not add rule.', true)
    return
  }

  $('ruleLabel').value = ''
  $('rulePoints').value = ''
  await loadAndRenderRules(selectedRulesStoreId, $('rulesStoreName').textContent)
  btn.disabled = false
}

// ── Manage store ──────────────────────────────────────────────────────────────

async function loadAndRenderManageStore(storeId, storeName) {
  $('manageStoreName').textContent = storeName
  $('manageStoreContent').classList.remove('hidden')
  $('manageManagersList').innerHTML = '<p class="empty">Loading...</p>'
  $('manageStaffList').innerHTML = '<p class="empty">Loading...</p>'
  setStatus('manageStoreStatus', '')

  const [{ data: managers, error: me }, { data: staff, error: se }] = await Promise.all([
    loadStoreManagers(storeId),
    loadStoreStaff(storeId)
  ])

  if (me) { $('manageManagersList').innerHTML = '<p class="empty">Could not load.</p>' }
  else { renderMemberList('manageManagersList', managers || [], 'data-remove-manager-id') }

  if (se) { $('manageStaffList').innerHTML = '<p class="empty">Could not load.</p>' }
  else { renderMemberList('manageStaffList', staff || [], 'data-remove-staff-id') }
}

// ── Applicants ────────────────────────────────────────────────────────────────

async function loadAndRenderApplicants() {
  const el = $('applicantsList')
  el.innerHTML = '<p class="empty">Loading...</p>'
  setStatus('applicantsStatus', '')

  const { data, error } = await loadAllApplicants()
  if (error) { el.innerHTML = '<p class="empty">Could not load applicants.</p>'; return }

  const applicants = data || []
  if (!applicants.length) { el.innerHTML = '<p class="empty">No pending applicants.</p>'; return }

  const grouped = {}
  applicants.forEach(a => {
    if (!grouped[a.store_id]) grouped[a.store_id] = []
    grouped[a.store_id].push(a)
  })

  el.innerHTML = Object.entries(grouped).map(([storeId, members]) => {
    const store = stores.find(s => s.id === storeId)
    const storeName = store ? escapeHtml(store.name) : escapeHtml(storeId)
    const rows = members.map(a => `
      <div class="dir-row">
        <div class="dir-info">
          <span class="dir-name">${escapeHtml(resolvePublicId(a.user_id))}</span>
          <span class="dir-sub">${escapeHtml(a.user_id)}</span>
        </div>
        <div class="dir-actions">
          <button class="btn-sm" data-approve-user-id="${escapeHtml(a.user_id)}" data-store-id="${escapeHtml(a.store_id)}">Approve</button>
          <button class="btn-danger-sm" data-reject-user-id="${escapeHtml(a.user_id)}" data-store-id="${escapeHtml(a.store_id)}">Reject</button>
        </div>
      </div>
    `).join('')
    return `<div class="applicant-group"><div class="applicant-group-title">${storeName}</div>${rows}</div>`
  }).join('')
}

// ── Utilities ─────────────────────────────────────────────────────────────────

function setStatus(id, message, isError = false) {
  const el = $(id)
  if (!el) return
  el.textContent = message
  el.classList.toggle('error', isError)
}

init()
