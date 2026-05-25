import { initAuth } from '../../services/auth.js'
import { refreshDebugUI } from '../../lib/adminContext.js'
import {
  assignManager, assignStaff,
  loadAdminUsers, loadAllStores,
  createStore, updateStoreName,
  loadRewardRules, insertRewardRule, deleteRewardRule, updateRewardRuleOrder,
  setBonusCap,
  loadStoreManagers, removeManager,
  loadStoreStaff, removeStaffAdmin,
  loadStoreMembers,
  uploadStoreLogo, setStoreLogo,
  loadStoreOutlets, createOutlet, updateOutlet, deleteOutlet,
  archiveStore, restoreStore, removeCustomerFromStore,
} from '../../services/admin.js'
import { getStoreBonusCap } from '../../services/stores.js'
import { getLogoUrl } from '../../lib/logoUrl.js'
import { escapeHtml } from '../../lib/escape.js'
import { $, $$, $q } from '../../lib/dom.js'

let users = []
let stores = []
let currentRules = []
let currentOutlets = []

let selectedManagerStoreId = null
let selectedStaffStoreId = null
let selectedRulesStoreId = null
let selectedManageStoreId = null
let selectedManageStoreName = null

let managerReqId = 0
let staffReqId = 0
let manageStoreReqId = 0

async function init() {
  try {
    const session = await initAuth()
    const [{ data: u, error: ue }, { data: s, error: se }] = await Promise.all([
      loadAdminUsers(),
      loadAllStores()
    ])
    if (ue) throw ue
    if (se) throw se

    users = u || []
    stores = s || []

    const me = users.find(u => u.user_id === session?.id)
    if (me?.public_id) $('adminId').textContent = me.public_id

    const activeStores = stores.filter(s => s.is_active !== false)
    renderPicker('managerStoreList', activeStores, 'store')
    renderPicker('staffStoreList', activeStores, 'store')
    renderPicker('rulesStoreList', activeStores, 'store')
    renderPicker('manageStoreList', activeStores, 'store')
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
  el.innerHTML = stores.map(s => {
    const archived = s.is_active === false
    const actions = archived
      ? `<button class="btn-sm" data-restore-store-id="${escapeHtml(s.id)}">Restore</button>`
      : `<button class="btn-sm" data-edit-store-id="${escapeHtml(s.id)}" data-store-name="${escapeHtml(s.name || '')}">Edit</button>
         <button class="btn-danger-sm" data-archive-store-id="${escapeHtml(s.id)}">Archive</button>`
    return `
    <div class="dir-row" data-store-id="${escapeHtml(s.id)}">
      <div class="dir-info">
        <span class="dir-name">${escapeHtml(s.name || 'Untitled')}</span>
        <span class="dir-sub">${escapeHtml(s.id)}</span>
      </div>
      ${archived ? '<span class="archived-badge">Archived</span>' : ''}
      <div class="dir-actions">${actions}</div>
    </div>`
  }).join('')
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
  $$('.action-btn[data-section]').forEach(btn => {
    btn.addEventListener('click', () => {
      showSection(btn.dataset.section, btn)
    })
  })

  $('managerStoreList')?.addEventListener('click', async e => {
    const btn = e.target.closest('[data-store-id]')
    if (!btn) return
    selectedManagerStoreId = btn.dataset.storeId
    selectInPicker('managerStoreList', btn)
    setStatus('assignManagerStatus', '')
    await loadAndRenderManagerCandidates(btn.dataset.storeId)
    refreshDebugUI(btn.dataset.storeId)
  })

  $('managerCandidatesList')?.addEventListener('click', async e => {
    const btn = e.target.closest('[data-make-manager-id]')
    if (!btn) return
    btn.disabled = true
    const { error } = await assignManager(btn.dataset.makeManagerId, selectedManagerStoreId)
    if (error) { btn.disabled = false; setStatus('assignManagerStatus', error.message || 'Could not assign.', true); return }
    setStatus('assignManagerStatus', 'Manager assigned.')
    await loadAndRenderManagerCandidates(selectedManagerStoreId)
  })

  $('staffStoreList')?.addEventListener('click', async e => {
    const btn = e.target.closest('[data-store-id]')
    if (!btn) return
    selectedStaffStoreId = btn.dataset.storeId
    selectInPicker('staffStoreList', btn)
    setStatus('assignStaffStatus', '')
    await loadAndRenderStaffCandidates(btn.dataset.storeId)
    refreshDebugUI(btn.dataset.storeId)
  })

  $('staffCandidatesList')?.addEventListener('click', async e => {
    const btn = e.target.closest('[data-make-staff-id]')
    if (!btn) return
    btn.disabled = true
    const { error } = await assignStaff(btn.dataset.makeStaffId, selectedStaffStoreId)
    if (error) { btn.disabled = false; setStatus('assignStaffStatus', error.message || 'Could not assign.', true); return }
    setStatus('assignStaffStatus', 'Staff assigned.')
    await loadAndRenderStaffCandidates(selectedStaffStoreId)
  })

  $('createStoreBtn')?.addEventListener('click', handleCreateStore)
  $('newStoreName')?.addEventListener('keydown', e => { if (e.key === 'Enter') handleCreateStore() })

  $('rulesStoreList')?.addEventListener('click', async e => {
    const btn = e.target.closest('[data-store-id]')
    if (!btn) return
    selectedRulesStoreId = btn.dataset.storeId
    selectInPicker('rulesStoreList', btn)
    await loadAndRenderRules(btn.dataset.storeId, btn.dataset.storeName)
    refreshDebugUI(btn.dataset.storeId)
  })

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

  $('saveBonusCapBtn')?.addEventListener('click', async () => {
    const val = parseInt($('bonusCapInput').value)
    if (!val || val < 1) { setStatus('bonusCapStatus', 'Enter a value of 1 or more.', true); return }
    const btn = $('saveBonusCapBtn')
    btn.disabled = true
    const { error } = await setBonusCap(selectedRulesStoreId, val)
    btn.disabled = false
    if (error) { setStatus('bonusCapStatus', error.message || 'Could not save.', true); return }
    setStatus('bonusCapStatus', `Cap set to ${val} pts.`)
  })

  $('removeBonusCapBtn')?.addEventListener('click', async () => {
    const btn = $('removeBonusCapBtn')
    btn.disabled = true
    const { error } = await setBonusCap(selectedRulesStoreId, null)
    btn.disabled = false
    if (error) { setStatus('bonusCapStatus', error.message || 'Could not remove.', true); return }
    $('bonusCapInput').value = ''
    setStatus('bonusCapStatus', 'Cap removed.')
  })

  $('allStoresList')?.addEventListener('click', async e => {
    const editBtn = e.target.closest('[data-edit-store-id]')
    if (editBtn) { showInlineEdit(editBtn.dataset.editStoreId, editBtn.dataset.storeName); return }

    const archiveBtn = e.target.closest('[data-archive-store-id]')
    if (archiveBtn) { await handleArchiveStore(archiveBtn); return }

    const restoreBtn = e.target.closest('[data-restore-store-id]')
    if (restoreBtn) { await handleRestoreStore(restoreBtn); return }

    const saveBtn = e.target.closest('[data-save-store-id]')
    if (saveBtn) await handleSaveStoreName(saveBtn)

    const cancelBtn = e.target.closest('[data-cancel-store-id]')
    if (cancelBtn) { renderAllStores(); setStatus('allStoresStatus', '') }
  })

  $('manageStoreList')?.addEventListener('click', async e => {
    const btn = e.target.closest('[data-store-id]')
    if (!btn) return
    selectedManageStoreId = btn.dataset.storeId
    selectedManageStoreName = btn.dataset.storeName
    selectInPicker('manageStoreList', btn)
    const reqId = ++manageStoreReqId
    await loadAndRenderManageStore(btn.dataset.storeId, btn.dataset.storeName, reqId)
    refreshDebugUI(btn.dataset.storeId)
  })

  $('logoFileInput')?.addEventListener('change', async e => {
    const file = e.target.files?.[0]
    if (!file || !selectedManageStoreId) return
    e.target.value = ''

    setStatus('logoUploadStatus', 'Uploading...')

    try {
      const blob = await processLogoFile(file)
      const path = `stores/${selectedManageStoreId}/logo.webp`

      const { error: uploadError } = await uploadStoreLogo(selectedManageStoreId, blob)
      if (uploadError) { setStatus('logoUploadStatus', uploadError.message, true); return }

      const { error: rpcError } = await setStoreLogo(selectedManageStoreId, path)
      if (rpcError) { setStatus('logoUploadStatus', rpcError.message, true); return }

      const updatedAt = new Date().toISOString()
      stores = stores.map(s =>
        s.id === selectedManageStoreId
          ? { ...s, logo_path: path, logo_updated_at: updatedAt }
          : s
      )

      renderManageLogo(selectedManageStoreId)
      setStatus('logoUploadStatus', 'Logo updated.')
    } catch {
      setStatus('logoUploadStatus', 'Could not process image. Use a different file.', true)
    }
  })

  $('manageManagersList')?.addEventListener('click', async e => {
    const btn = e.target.closest('[data-remove-manager-id]')
    if (!btn) return
    btn.disabled = true
    const reqId = manageStoreReqId
    const { error } = await removeManager(btn.dataset.removeManagerId, selectedManageStoreId)
    if (reqId !== manageStoreReqId) return
    if (error) { btn.disabled = false; setStatus('manageStoreStatus', error.message || 'Could not remove.', true); return }
    await loadAndRenderManageStore(selectedManageStoreId, selectedManageStoreName, reqId)
  })

  $('manageStaffList')?.addEventListener('click', async e => {
    const btn = e.target.closest('[data-remove-staff-id]')
    if (!btn) return
    btn.disabled = true
    const reqId = manageStoreReqId
    const { error } = await removeStaffAdmin(btn.dataset.removeStaffId, selectedManageStoreId)
    if (reqId !== manageStoreReqId) return
    if (error) { btn.disabled = false; setStatus('manageStoreStatus', error.message || 'Could not remove.', true); return }
    await loadAndRenderManageStore(selectedManageStoreId, selectedManageStoreName, reqId)
  })

  $('manageMembersList')?.addEventListener('click', async e => {
    const btn = e.target.closest('[data-remove-customer-id]')
    if (!btn) return
    await handleRemoveCustomer(btn.dataset.removeCustomerId, btn)
  })

  // ── Outlets ────────────────────────────────────────────────────────────────

  $('addOutletBtn')?.addEventListener('click', handleAddOutletRow)

  $('manageOutletsList')?.addEventListener('click', async e => {
    const renameBtn = e.target.closest('[data-rename-outlet-id]')
    if (renameBtn) {
      showOutletInlineEdit(renameBtn.dataset.renameOutletId, renameBtn.dataset.outletName)
      return
    }

    const saveRenameBtn = e.target.closest('[data-save-outlet-id]')
    if (saveRenameBtn) {
      await handleSaveOutletRename(saveRenameBtn.dataset.saveOutletId)
      return
    }

    const cancelRenameBtn = e.target.closest('[data-cancel-outlet-id]')
    if (cancelRenameBtn) {
      renderOutletsList(currentOutlets)
      return
    }

    const saveNewBtn = e.target.closest('[data-save-new-outlet]')
    if (saveNewBtn) {
      await handleSaveNewOutlet()
      return
    }

    const cancelNewBtn = e.target.closest('[data-cancel-new-outlet]')
    if (cancelNewBtn) {
      renderOutletsList(currentOutlets)
      return
    }

    const removeBtn = e.target.closest('[data-remove-outlet-id]')
    if (removeBtn) {
      await handleDeleteOutlet(removeBtn.dataset.removeOutletId, removeBtn)
    }
  })
}

// ── Section nav ───────────────────────────────────────────────────────────────

function showSection(name, activeBtn) {
  $$('#panelArea .panel').forEach(p => p.classList.add('hidden'))
  $$('.action-btn[data-section]').forEach(b => b.classList.remove('active'))
  const panel = $(`panel-${name}`)
  if (panel) panel.classList.remove('hidden')
  if (activeBtn) activeBtn.classList.add('active')
}

function selectInPicker(containerId, activeBtn) {
  $$(`#${containerId} .pick-card`).forEach(b => {
    b.classList.toggle('selected', b === activeBtn)
  })
}

// ── Manager candidates (race-safe) ────────────────────────────────────────────

async function loadAndRenderManagerCandidates(storeId) {
  const el = $('managerCandidatesList')
  const reqId = ++managerReqId

  el.innerHTML = '<p class="empty">Loading...</p>'

  const [{ data: managers, error }, { data: members }] = await Promise.all([
    loadStoreManagers(storeId),
    loadStoreMembers(storeId)
  ])

  if (reqId !== managerReqId) return
  if (error) { el.innerHTML = '<p class="empty">Could not load.</p>'; return }

  const managerIds = new Set((managers || []).map(m => m.user_id))
  const memberIds  = new Set((members  || []).map(m => m.user_id))

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

  const candidates = users.filter(u => memberIds.has(u.user_id) && !managerIds.has(u.user_id))
  const candidateHtml = candidates.length
    ? candidates.map(u => `
        <div class="dir-row">
          <div class="dir-info">
            <span class="dir-name">${escapeHtml(u.public_id || u.user_id)}</span>
            <span class="dir-sub">${escapeHtml(u.user_id)}</span>
          </div>
          <div class="dir-actions">
            <button class="btn-sm" data-make-manager-id="${escapeHtml(u.user_id)}">Make Manager</button>
          </div>
        </div>`).join('')
    : '<p class="empty">No users available.</p>'

  el.innerHTML = `
    <div class="candidate-group-title">Current Managers</div>
    ${managerHtml}
    <div class="candidate-group-title" style="margin-top:12px">All Users</div>
    ${candidateHtml}
  `
}

// ── Staff candidates (race-safe) ──────────────────────────────────────────────

async function loadAndRenderStaffCandidates(storeId) {
  const el = $('staffCandidatesList')
  const reqId = ++staffReqId

  el.innerHTML = '<p class="empty">Loading...</p>'

  const [{ data: staff, error }, { data: members }] = await Promise.all([
    loadStoreStaff(storeId),
    loadStoreMembers(storeId)
  ])

  if (reqId !== staffReqId) return
  if (error) { el.innerHTML = '<p class="empty">Could not load.</p>'; return }

  const staffIds  = new Set((staff   || []).map(s => s.user_id))
  const memberIds = new Set((members || []).map(m => m.user_id))

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

  const candidates = users.filter(u => memberIds.has(u.user_id) && !staffIds.has(u.user_id))
  const candidateHtml = candidates.length
    ? candidates.map(u => `
        <div class="dir-row">
          <div class="dir-info">
            <span class="dir-name">${escapeHtml(u.public_id || u.user_id)}</span>
            <span class="dir-sub">${escapeHtml(u.user_id)}</span>
          </div>
          <div class="dir-actions">
            <button class="btn-sm" data-make-staff-id="${escapeHtml(u.user_id)}">Make Staff</button>
          </div>
        </div>`).join('')
    : '<p class="empty">No users available.</p>'

  el.innerHTML = `
    <div class="candidate-group-title">Current Staff</div>
    ${staffHtml}
    <div class="candidate-group-title" style="margin-top:12px">All Users</div>
    ${candidateHtml}
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

  if (error || !data) {
    setStatus('createStoreStatus', error?.message || 'Could not create store.', true)
    return
  }

  $('newStoreName').value = ''
  setStatus('createStoreStatus', `"${data.name}" created.`)

  stores = [...stores, { id: data.id, name: data.name, is_active: true }]
  refreshAllStorePickers()

  // Navigate directly to Manage Store and auto-select the new store.
  // The new store already has a 'Main' outlet (created atomically by the RPC).
  const manageNavBtn = $q('.action-btn[data-section="manageStore"]')
  showSection('manageStore', manageNavBtn)
  selectedManageStoreId   = data.id
  selectedManageStoreName = data.name
  const pickerBtn = $q(`#manageStoreList [data-store-id="${CSS.escape(data.id)}"]`)
  if (pickerBtn) selectInPicker('manageStoreList', pickerBtn)
  const reqId = ++manageStoreReqId
  await loadAndRenderManageStore(data.id, data.name, reqId)
}

function refreshAllStorePickers() {
  const activeStores = stores.filter(s => s.is_active !== false)
  renderPicker('managerStoreList', activeStores, 'store')
  renderPicker('staffStoreList', activeStores, 'store')
  renderPicker('rulesStoreList', activeStores, 'store')
  renderPicker('manageStoreList', activeStores, 'store')
  renderAllStores()

  if (selectedManagerStoreId) {
    const btn = $q(`#managerStoreList [data-store-id="${CSS.escape(selectedManagerStoreId)}"]`)
    if (btn) btn.classList.add('selected')
  }
  if (selectedStaffStoreId) {
    const btn = $q(`#staffStoreList [data-store-id="${CSS.escape(selectedStaffStoreId)}"]`)
    if (btn) btn.classList.add('selected')
  }
  if (selectedRulesStoreId) {
    const btn = $q(`#rulesStoreList [data-store-id="${CSS.escape(selectedRulesStoreId)}"]`)
    if (btn) btn.classList.add('selected')
  }
  if (selectedManageStoreId) {
    const btn = $q(`#manageStoreList [data-store-id="${CSS.escape(selectedManageStoreId)}"]`)
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

  if (error || !data) {
    setStatus('allStoresStatus', error?.message || 'Could not update name.', true)
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

async function handleArchiveStore(archiveBtn) {
  const storeId = archiveBtn.dataset.archiveStoreId

  if (!confirmStep(archiveBtn, 'Archive')) return

  archiveBtn.disabled = true
  const { error } = await archiveStore(storeId)
  if (error) {
    archiveBtn.disabled = false
    setStatus('allStoresStatus', error.message || 'Could not archive store.', true)
    return
  }

  stores = stores.map(s =>
    s.id === storeId ? { ...s, is_active: false, deleted_at: new Date().toISOString() } : s
  )

  // Remove archived store from section pickers — pickers only show active stores
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

  renderAllStores()
  refreshAllStorePickers()
  setStatus('allStoresStatus', 'Store archived.')
}

async function handleRestoreStore(restoreBtn) {
  const storeId = restoreBtn.dataset.restoreStoreId

  restoreBtn.disabled = true
  const { error } = await restoreStore(storeId)
  if (error) {
    restoreBtn.disabled = false
    setStatus('allStoresStatus', error.message || 'Could not restore store.', true)
    return
  }

  stores = stores.map(s =>
    s.id === storeId ? { ...s, is_active: true, deleted_at: null } : s
  )

  renderAllStores()
  refreshAllStorePickers()
  setStatus('allStoresStatus', 'Store restored.')
}

async function handleRemoveCustomer(userId, btn) {
  if (!confirmStep(btn, 'Remove')) return
  btn.disabled = true
  const reqId = manageStoreReqId
  const { error } = await removeCustomerFromStore(userId, selectedManageStoreId)
  if (reqId !== manageStoreReqId) return
  if (error) {
    btn.disabled = false
    setStatus('manageMembersStatus', error.message || 'Could not remove customer.', true)
    return
  }
  await loadAndRenderManageStore(selectedManageStoreId, selectedManageStoreName, reqId)
}

// ── Reward rules ──────────────────────────────────────────────────────────────

async function loadAndRenderRules(storeId, storeName) {
  $('rulesStoreName').textContent = storeName
  $('rulesContent').classList.remove('hidden')
  $('rulesList').innerHTML = '<p class="empty">Loading...</p>'
  $('bonusCapStatus').textContent = ''

  const [{ data, error }, { data: capData }] = await Promise.all([
    loadRewardRules(storeId),
    getStoreBonusCap(storeId)
  ])

  if (error) {
    $('rulesList').innerHTML = '<p class="empty">Could not load rules.</p>'
    return
  }

  currentRules = data || []
  renderRulesList()

  const cap = capData ?? null
  $('bonusCapInput').value = cap !== null ? cap : ''
  $('bonusCapInput').placeholder = cap !== null ? String(cap) : 'No cap'
}

const KIND_LABEL = { award: 'Award', redeem: 'Redeem', bonus_reason: 'Bonus Reason', bonus_amount: 'Bonus Amt' }

function renderRulesList() {
  if (!currentRules.length) {
    $('rulesList').innerHTML = '<p class="empty">No rules yet. Add one below.</p>'
    return
  }

  $('rulesList').innerHTML = currentRules.map((r, i) => {
    let ptsDisplay
    if (r.kind === 'bonus_reason') ptsDisplay = '—'
    else if (r.kind === 'redeem')  ptsDisplay = `−${r.points} pts`
    else                           ptsDisplay = `+${r.points} pts`

    return `
    <div class="rule-row">
      <div class="rule-order-btns">
        <button class="rule-order-btn" data-move-rule-id="${r.id}" data-direction="up" ${i === 0 ? 'disabled' : ''}>↑</button>
        <button class="rule-order-btn" data-move-rule-id="${r.id}" data-direction="down" ${i === currentRules.length - 1 ? 'disabled' : ''}>↓</button>
      </div>
      <span class="rule-badge" data-kind="${escapeHtml(r.kind)}">${KIND_LABEL[r.kind] || escapeHtml(r.kind)}</span>
      <span class="rule-label-text">${escapeHtml(r.label || '—')}</span>
      <span class="rule-pts-text">${ptsDisplay}</span>
      <button class="rule-delete-btn" data-delete-rule-id="${r.id}">Remove</button>
    </div>
  `}).join('')
}

async function handleMoveRule(ruleId, direction) {
  const idx = currentRules.findIndex(r => r.id === ruleId)
  if (idx === -1) return
  const swapIdx = direction === 'up' ? idx - 1 : idx + 1
  if (swapIdx < 0 || swapIdx >= currentRules.length) return

  ;[currentRules[idx], currentRules[swapIdx]] = [currentRules[swapIdx], currentRules[idx]]
  currentRules.forEach((r, i) => { r.sort_order = i + 1 })
  renderRulesList()

  const [{ error: e1 }, { error: e2 }] = await Promise.all([
    updateRewardRuleOrder(currentRules[idx].id, currentRules[idx].sort_order),
    updateRewardRuleOrder(currentRules[swapIdx].id, currentRules[swapIdx].sort_order)
  ])
  if (e1 || e2) {
    await loadAndRenderRules(selectedRulesStoreId, $('rulesStoreName').textContent)
  }
}

async function handleAddRule() {
  const label = $('ruleLabel').value.trim()
  const points = parseInt($('rulePoints').value, 10)
  const kind = $('ruleKind').value

  if (kind === 'bonus_reason') {
    if (!label) { setStatus('addRuleStatus', 'Bonus reason needs a label.', true); return }
  } else if (kind === 'bonus_amount') {
    if (!points || points < 1) { setStatus('addRuleStatus', 'Bonus amount needs a point value.', true); return }
  } else {
    if (!points || points < 1) { setStatus('addRuleStatus', 'Enter a valid point value.', true); return }
    if (kind === 'award' && !label) { setStatus('addRuleStatus', 'Award rules need a label.', true); return }
  }

  const effectivePoints = kind === 'bonus_reason' ? 0 : points

  const btn = $('addRuleBtn')
  btn.disabled = true
  $('addRuleStatus').textContent = ''

  const { error } = await insertRewardRule(selectedRulesStoreId, { label, points: effectivePoints, kind }, currentRules.length + 1)

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

// ── Store logo ────────────────────────────────────────────────────────────────

async function processLogoFile(file) {
  const TARGET = 256
  const bitmap = await createImageBitmap(file)
  const size   = Math.min(bitmap.width, bitmap.height)
  const canvas = document.createElement('canvas')
  canvas.width  = TARGET
  canvas.height = TARGET
  const ctx = canvas.getContext('2d')
  const sx  = (bitmap.width  - size) / 2
  const sy  = (bitmap.height - size) / 2
  ctx.drawImage(bitmap, sx, sy, size, size, 0, 0, TARGET, TARGET)
  return new Promise((resolve, reject) => {
    canvas.toBlob(
      blob => blob ? resolve(blob) : reject(new Error('Image conversion failed')),
      'image/webp',
      0.82
    )
  })
}

function renderManageLogo(storeId) {
  const el = $('manageStoreLogo')
  if (!el) return
  const store = stores.find(s => s.id === storeId)
  const url   = store ? getLogoUrl(store.logo_path, store.logo_updated_at) : null
  if (url) {
    el.innerHTML = `<img src="${escapeHtml(url)}" width="48" height="48" alt="Store logo" onerror="this.style.display='none'">`
  } else {
    el.innerHTML = '<span class="logo-none">No logo</span>'
  }
}

// ── Manage store ──────────────────────────────────────────────────────────────

async function loadAndRenderManageStore(storeId, storeName, reqId) {
  $('manageStoreName').textContent = storeName
  $('manageStoreContent').classList.remove('hidden')
  renderManageLogo(storeId)
  $('manageManagersList').innerHTML = '<p class="empty">Loading...</p>'
  $('manageStaffList').innerHTML    = '<p class="empty">Loading...</p>'
  $('manageMembersList').innerHTML  = '<p class="empty">Loading...</p>'
  $('manageOutletsList').innerHTML  = '<p class="empty">Loading...</p>'
  setStatus('manageStoreStatus', '')
  setStatus('manageMembersStatus', '')
  setStatus('manageOutletsStatus', '')

  const [
    { data: managers, error: me },
    { data: staff,    error: se },
    { data: members,  error: mbe },
    { data: outlets,  error: oe },
  ] = await Promise.all([
    loadStoreManagers(storeId),
    loadStoreStaff(storeId),
    loadStoreMembers(storeId),
    loadStoreOutlets(storeId),
  ])

  if (reqId !== manageStoreReqId) return

  if (me)  { $('manageManagersList').innerHTML = '<p class="empty">Could not load.</p>' }
  else     { renderMemberList('manageManagersList', managers || [], 'data-remove-manager-id') }

  if (se)  { $('manageStaffList').innerHTML = '<p class="empty">Could not load.</p>' }
  else     { renderMemberList('manageStaffList', staff || [], 'data-remove-staff-id') }

  if (mbe) { $('manageMembersList').innerHTML = '<p class="empty">Could not load.</p>' }
  else     { renderMemberList('manageMembersList', members || [], 'data-remove-customer-id') }

  if (oe)  { $('manageOutletsList').innerHTML = '<p class="empty">Could not load.</p>' }
  else     { currentOutlets = outlets || []; renderOutletsList(currentOutlets) }
}

// ── Outlets ───────────────────────────────────────────────────────────────────

// TODO: outlets are ordered alphabetically (ORDER BY name in load_store_outlets RPC).
// If manual ordering is needed, add sort_order to store_outlets and update the RPC.

function renderOutletsList(outlets) {
  const el = $('manageOutletsList')
  if (!el) return
  if (!outlets.length) {
    el.innerHTML = '<p class="empty">No outlets yet.</p>'
    return
  }
  el.innerHTML = outlets.map(o => `
    <div class="dir-row" data-outlet-id="${escapeHtml(o.id)}">
      <div class="dir-info">
        <span class="dir-name">${escapeHtml(o.name)}</span>
      </div>
      <div class="dir-actions">
        <button class="btn-sm"
          data-rename-outlet-id="${escapeHtml(o.id)}"
          data-outlet-name="${escapeHtml(o.name)}">Rename</button>
        <button class="btn-danger-sm"
          data-remove-outlet-id="${escapeHtml(o.id)}">Remove</button>
      </div>
    </div>
  `).join('')
}

function handleAddOutletRow() {
  const el = $('manageOutletsList')
  if (!el) return
  if (el.querySelector('[data-new-outlet-row]')) return  // prevent duplicates
  const row = document.createElement('div')
  row.className = 'inline-edit-row'
  row.dataset.newOutletRow = 'true'
  row.innerHTML = `
    <input class="input input-grow" placeholder="Outlet name…" />
    <button class="btn-sm" data-save-new-outlet>Save</button>
    <button class="btn-danger-sm" data-cancel-new-outlet>Cancel</button>
  `
  el.appendChild(row)
  row.querySelector('input')?.focus()
}

async function handleSaveNewOutlet() {
  const el = $('manageOutletsList')
  const row = el?.querySelector('[data-new-outlet-row]')
  const input = row?.querySelector('input')
  const name = input?.value.trim()
  if (!name) { renderOutletsList(currentOutlets); return }

  const saveBtn = row?.querySelector('[data-save-new-outlet]')
  if (saveBtn) saveBtn.disabled = true

  const reqId = manageStoreReqId
  const { error } = await createOutlet(selectedManageStoreId, name)
  if (reqId !== manageStoreReqId) return
  if (error) {
    if (saveBtn) saveBtn.disabled = false
    setStatus('manageOutletsStatus', error.message || 'Could not create outlet.', true)
    return
  }
  await loadAndRenderManageStore(selectedManageStoreId, selectedManageStoreName, reqId)
}

function showOutletInlineEdit(outletId, currentName) {
  const el = $('manageOutletsList')
  const row = el?.querySelector(`[data-outlet-id="${CSS.escape(outletId)}"]`)
  if (!row) return
  row.outerHTML = `
    <div class="inline-edit-row" data-outlet-id="${escapeHtml(outletId)}">
      <input class="input input-grow"
        value="${escapeHtml(currentName)}"
        id="outlet-edit-input-${escapeHtml(outletId)}" />
      <button class="btn-sm" data-save-outlet-id="${escapeHtml(outletId)}">Save</button>
      <button class="btn-danger-sm" data-cancel-outlet-id="${escapeHtml(outletId)}">Cancel</button>
    </div>
  `
  $(`outlet-edit-input-${outletId}`)?.focus()
}

async function handleSaveOutletRename(outletId) {
  const input = $(`outlet-edit-input-${outletId}`)
  const name = input?.value.trim()
  if (!name) { renderOutletsList(currentOutlets); return }

  const saveBtn = $('manageOutletsList')
    ?.querySelector(`[data-save-outlet-id="${CSS.escape(outletId)}"]`)
  if (saveBtn) saveBtn.disabled = true

  const reqId = manageStoreReqId
  const { error } = await updateOutlet(outletId, name)
  if (reqId !== manageStoreReqId) return
  if (error) {
    if (saveBtn) saveBtn.disabled = false
    setStatus('manageOutletsStatus', error.message || 'Could not rename outlet.', true)
    return
  }
  await loadAndRenderManageStore(selectedManageStoreId, selectedManageStoreName, reqId)
}

async function handleDeleteOutlet(outletId, btn) {
  if (!confirmStep(btn, 'Remove')) return
  btn.disabled = true
  const reqId = manageStoreReqId
  const { error } = await deleteOutlet(outletId)
  if (reqId !== manageStoreReqId) return
  if (error) {
    // Reset confirm state so the button returns to its normal label.
    btn.disabled = false
    btn.dataset.confirm = ''
    btn.textContent = 'Remove'
    // The server returns the reason directly (e.g. "last outlet" constraint).
    setStatus('manageOutletsStatus', error.message || 'Could not delete outlet.', true)
    return
  }
  await loadAndRenderManageStore(selectedManageStoreId, selectedManageStoreName, reqId)
}

// ── Utilities ─────────────────────────────────────────────────────────────────

// Double-confirm helper for destructive buttons.
// First call shows "Sure?" and returns false. Second call returns true.
// Works with delegated event listeners — no binding needed.
function confirmStep(btn, originalLabel, ms = 3000) {
  if (btn.dataset.confirm !== 'true') {
    btn.dataset.confirm = 'true'
    btn.textContent = 'Sure?'
    setTimeout(() => {
      if (btn.dataset.confirm === 'true') {
        btn.dataset.confirm = ''
        btn.textContent = originalLabel
      }
    }, ms)
    return false
  }
  return true
}

function setStatus(id, message, isError = false) {
  const el = $(id)
  if (!el) return
  el.textContent = message
  el.classList.toggle('error', isError)
}

init()
