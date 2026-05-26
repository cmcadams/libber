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
import { $ } from '../../lib/dom.js'

// ── State ─────────────────────────────────────────────────────────────────────
let allStores = []
let allUsers  = []

let currentStoreId   = null
let currentStoreName = null
let loadSeq  = 0    // race guard for store detail loads

let rulesLocal   = []  // local copy for optimistic reorder
let outletsLocal = []  // local copy for outlet list render

// ── Init ──────────────────────────────────────────────────────────────────────

async function init() {
  try {
    await initAuth()
    const [{ data: users, error: ue }, { data: stores, error: se }] = await Promise.all([
      loadAdminUsers(),
      loadAllStores(),
    ])
    if (ue) throw ue
    if (se) throw se

    allUsers  = users  || []
    allStores = stores || []

    renderStoreGrid()
    renderAllUsers()
    bindEvents()
  } catch (err) {
    console.error('Admin init failed:', err)
  }
}

// ── View switching ────────────────────────────────────────────────────────────

function showStoreList() {
  $('viewStores').classList.remove('hidden')
  $('viewStore').classList.add('hidden')
  currentStoreId   = null
  currentStoreName = null
  renderStoreGrid()
  refreshDebugUI(null)
}

async function showStoreDetail(storeId, storeName) {
  currentStoreId   = storeId
  currentStoreName = storeName
  $('viewStores').classList.add('hidden')
  $('viewStore').classList.remove('hidden')
  refreshDebugUI(storeId)
  await loadAndRenderStoreDetail(storeId)
}

// ── Store grid ────────────────────────────────────────────────────────────────

function renderStoreGrid() {
  const el = $('storeGrid')
  if (!el) return

  if (!allStores.length) {
    el.innerHTML = '<p class="empty">No stores yet. Hit "+ New Store" to create one.</p>'
    return
  }

  el.innerHTML = allStores.map(s => {
    const logoUrl  = getLogoUrl(s.logo_path, s.logo_updated_at)
    const archived = s.is_active === false
    const initial  = escapeHtml((s.name || '?').charAt(0).toUpperCase())
    const logoHtml = logoUrl
      ? `<img src="${escapeHtml(logoUrl)}" width="44" height="44" alt="" onerror="this.style.display='none'">`
      : `<span class="logo-initial">${initial}</span>`
    return `
      <button class="store-card${archived ? ' archived' : ''}"
              data-store-id="${escapeHtml(s.id)}"
              data-store-name="${escapeHtml(s.name || 'Untitled')}">
        <div class="store-card-logo">${logoHtml}</div>
        <div class="store-card-body">
          <span class="store-card-name">${escapeHtml(s.name || 'Untitled')}</span>
          <span class="badge ${archived ? 'badge-archived' : 'badge-active'}">${archived ? 'Archived' : 'Active'}</span>
        </div>
        <span class="store-card-arrow">→</span>
      </button>`
  }).join('')
}

function renderAllUsers() {
  const el = $('allUsersList')
  if (!el) return
  if (!allUsers.length) { el.innerHTML = '<p class="empty">No users yet.</p>'; return }
  el.innerHTML = allUsers.map(u => `
    <div class="dir-row">
      <div class="dir-info">
        <span class="dir-name">${escapeHtml(u.public_id || '—')}</span>
        <span class="dir-sub">${escapeHtml(u.user_id)}</span>
      </div>
    </div>`).join('')
}

// ── Store detail: load all data ───────────────────────────────────────────────

async function loadAndRenderStoreDetail(storeId) {
  const seq = ++loadSeq

  // Show skeleton immediately
  setSectionLoading('storeHeader',     'Loading…')
  setSectionLoading('sectionManagers', 'Loading…')
  setSectionLoading('sectionStaff',    'Loading…')
  setSectionLoading('sectionMembers',  'Loading…')
  setSectionLoading('sectionRewards',  'Loading…')
  setSectionLoading('sectionOutlets',  'Loading…')

  const store = allStores.find(s => s.id === storeId) || { id: storeId, name: currentStoreName }

  const [
    { data: managers, error: me  },
    { data: staff,    error: se  },
    { data: members,  error: mbe },
    { data: outlets,  error: oe  },
    { data: rules,    error: re  },
    { data: bonusCap },
  ] = await Promise.all([
    loadStoreManagers(storeId),
    loadStoreStaff(storeId),
    loadStoreMembers(storeId),
    loadStoreOutlets(storeId),
    loadRewardRules(storeId),
    getStoreBonusCap(storeId),
  ])

  if (seq !== loadSeq) return  // superseded by a newer load

  // De-duplicate people sections: each person appears in at most one section
  const managerIds = new Set((managers || []).map(m => m.user_id))
  const staffIds   = new Set((staff    || []).map(s => s.user_id))
  const pureStaff  = (staff || []).filter(s => !managerIds.has(s.user_id))
  const pureMembers = (members || []).filter(m => !staffIds.has(m.user_id) && !managerIds.has(m.user_id))

  rulesLocal   = rules   ? [...rules]   : []
  outletsLocal = outlets ? [...outlets] : []

  // Sync store state (logo/active may have changed from header actions)
  const freshStore = allStores.find(s => s.id === storeId) || store

  renderStoreHeader(freshStore)
  renderManagers(managers || [], me)
  renderStaff(pureStaff, se)
  renderMembers(pureMembers, mbe)
  renderRewards(rulesLocal, bonusCap ?? null, re)
  renderOutlets(outletsLocal, oe)
}

function setSectionLoading(id, text) {
  const el = $(id)
  if (el) el.innerHTML = `<p class="loading-text">${escapeHtml(text)}</p>`
}

// ── Store header ──────────────────────────────────────────────────────────────

function renderStoreHeader(store) {
  const logoUrl  = getLogoUrl(store.logo_path, store.logo_updated_at)
  const archived = store.is_active === false
  const initial  = escapeHtml((store.name || '?').charAt(0).toUpperCase())

  const logoHtml = logoUrl
    ? `<img src="${escapeHtml(logoUrl)}" width="64" height="64" alt="" onerror="this.style.display='none'">`
    : `<span class="logo-initial-lg">${initial}</span>`

  $('storeHeader').innerHTML = `
    <div class="store-detail-layout">
      <div class="store-detail-logo-wrap">
        <div class="store-detail-logo" id="headerLogoSlot">${logoHtml}</div>
        <label class="btn-sm logo-upload-label" style="font-size:11px">
          ${logoUrl ? 'Change' : 'Add logo'}
          <input type="file" id="logoFileInput" accept="image/*" style="display:none">
        </label>
      </div>
      <div class="store-detail-info">
        <div class="store-name-display" id="storeNameDisplay">
          <h2 class="store-detail-name" id="storeDetailName">${escapeHtml(store.name || 'Untitled')}</h2>
          <span class="badge ${archived ? 'badge-archived' : 'badge-active'}" id="storeStatusBadge">
            ${archived ? 'Archived' : 'Active'}
          </span>
          <div class="store-name-actions">
            <button class="btn-sm" id="editNameBtn">Rename</button>
            <button class="${archived ? 'btn-sm' : 'btn-danger-sm'}" id="archiveRestoreBtn">
              ${archived ? 'Restore' : 'Archive'}
            </button>
          </div>
        </div>
        <div class="store-name-edit-row hidden" id="storeNameEditRow">
          <input class="input" id="storeNameInput" value="${escapeHtml(store.name || '')}" style="width:220px" />
          <button class="btn-primary" id="saveNameBtn" style="padding:8px 16px">Save</button>
          <button class="btn-sm" id="cancelNameBtn">Cancel</button>
        </div>
        <div class="status" id="storeHeaderStatus"></div>
        <div class="status" id="logoUploadStatus"></div>
      </div>
    </div>
  `

  // Bind header-specific events (re-bound each render because innerHTML replaces elements)
  $('logoFileInput')?.addEventListener('change', handleLogoUpload)

  $('editNameBtn')?.addEventListener('click', () => {
    $('storeNameDisplay').classList.add('hidden')
    $('storeNameEditRow').classList.remove('hidden')
    $('storeNameInput').focus()
    $('storeNameInput').select()
  })

  $('cancelNameBtn')?.addEventListener('click', () => {
    $('storeNameDisplay').classList.remove('hidden')
    $('storeNameEditRow').classList.add('hidden')
    setStatus('storeHeaderStatus', '')
  })

  $('saveNameBtn')?.addEventListener('click', handleSaveStoreName)
  $('storeNameInput')?.addEventListener('keydown', e => { if (e.key === 'Enter') handleSaveStoreName() })

  $('archiveRestoreBtn')?.addEventListener('click', handleArchiveRestore)
}

// ── Section renderers ─────────────────────────────────────────────────────────

function renderManagers(managers, error) {
  const count = managers.length
  const title = `Managers${count ? ` (${count})` : ''}`

  if (error) {
    $('sectionManagers').innerHTML = sectionWrap(title, '<p class="error-text">Could not load.</p>')
    return
  }

  const rows = count
    ? managers.map(m => personRow(m.user_id, [
        `<span class="role-badge">Manager</span>`,
        `<button class="btn-danger-sm" data-demote-manager="${escapeHtml(m.user_id)}">Demote</button>`,
      ])).join('')
    : '<p class="empty">No managers yet.</p>'

  $('sectionManagers').innerHTML = sectionWrap(title, `<div class="dir-list">${rows}</div>`)
}

function renderStaff(staff, error) {
  const count = staff.length
  const title = `Staff${count ? ` (${count})` : ''}`

  if (error) {
    $('sectionStaff').innerHTML = sectionWrap(title, '<p class="error-text">Could not load.</p>')
    return
  }

  const rows = count
    ? staff.map(s => personRow(s.user_id, [
        `<span class="role-badge">Staff</span>`,
        `<button class="btn-sm" data-promote-to-mgr="${escapeHtml(s.user_id)}">→ Manager</button>`,
        `<button class="btn-danger-sm" data-demote-staff="${escapeHtml(s.user_id)}">Demote</button>`,
      ])).join('')
    : '<p class="empty">No staff yet.</p>'

  $('sectionStaff').innerHTML = sectionWrap(title, `<div class="dir-list">${rows}</div>`)
}

function renderMembers(members, error) {
  const count = members.length
  const title = `Members${count ? ` (${count})` : ''}`

  if (error) {
    $('sectionMembers').innerHTML = sectionWrap(title, '<p class="error-text">Could not load.</p>')
    return
  }

  const rows = count
    ? members.map(m => personRow(m.user_id, [
        `<button class="btn-sm" data-promote-to-staff="${escapeHtml(m.user_id)}">→ Staff</button>`,
        `<button class="btn-sm" data-promote-to-mgr="${escapeHtml(m.user_id)}">→ Manager</button>`,
        `<button class="btn-danger-sm" data-remove-member="${escapeHtml(m.user_id)}">Remove</button>`,
      ])).join('')
    : '<p class="empty">No members yet.</p>'

  $('sectionMembers').innerHTML = sectionWrap(title, `<div class="dir-list">${rows}</div>`)
}

const KIND_LABEL = { award: 'Award', redeem: 'Redeem', bonus_reason: 'Bonus Reason', bonus_amount: 'Bonus Amt' }

function renderRewards(rules, bonusCap, error) {
  if (error) {
    $('sectionRewards').innerHTML = sectionWrap('Rewards', '<p class="error-text">Could not load.</p>')
    return
  }

  const ruleRows = rules.length
    ? rules.map((r, i) => {
        let pts
        if (r.kind === 'bonus_reason')  pts = '—'
        else if (r.kind === 'redeem')   pts = `−${r.points} pts`
        else                            pts = `+${r.points} pts`
        return `
          <div class="rule-row">
            <div class="rule-order-btns">
              <button class="rule-order-btn" data-move-rule="${escapeHtml(r.id)}" data-direction="up" ${i === 0 ? 'disabled' : ''}>↑</button>
              <button class="rule-order-btn" data-move-rule="${escapeHtml(r.id)}" data-direction="down" ${i === rules.length - 1 ? 'disabled' : ''}>↓</button>
            </div>
            <span class="rule-badge" data-kind="${escapeHtml(r.kind)}">${KIND_LABEL[r.kind] || escapeHtml(r.kind)}</span>
            <span class="rule-label-text">${escapeHtml(r.label || '—')}</span>
            <span class="rule-pts-text">${pts}</span>
            <button class="rule-delete-btn" data-delete-rule="${escapeHtml(r.id)}">Remove</button>
          </div>`
      }).join('')
    : '<p class="empty">No rules yet.</p>'

  const content = `
    <div class="sub-section">
      <div class="sub-section-title">Rules</div>
      <div class="rules-list" id="rulesList">${ruleRows}</div>
    </div>
    <div class="sub-section">
      <div class="sub-section-title">Add Rule</div>
      <div class="rule-inputs">
        <select id="ruleKind" class="input">
          <optgroup label="Award / Redeem">
            <option value="award">Award</option>
            <option value="redeem">Redeem</option>
          </optgroup>
          <optgroup label="Bonus">
            <option value="bonus_reason">Bonus Reason</option>
            <option value="bonus_amount">Bonus Amount</option>
          </optgroup>
        </select>
        <input type="text" id="ruleLabel" placeholder="Label" class="input input-grow" />
        <input type="number" id="rulePoints" placeholder="Pts" class="input input-pts" min="1" />
        <button class="btn-primary" id="addRuleBtn" style="padding:10px 16px">Add</button>
      </div>
      <div class="status" id="addRuleStatus"></div>
    </div>
    <div class="sub-section">
      <div class="sub-section-title">Bonus Cap</div>
      <div class="form-row">
        <input type="number" id="bonusCapInput" class="input input-pts"
               value="${bonusCap !== null ? escapeHtml(String(bonusCap)) : ''}"
               placeholder="None" min="1" />
        <button class="btn-sm" id="saveBonusCapBtn">Save cap</button>
        <button class="btn-danger-sm" id="removeBonusCapBtn">Remove cap</button>
      </div>
      <div class="status" id="bonusCapStatus"></div>
    </div>
  `

  $('sectionRewards').innerHTML = sectionWrap(`Rewards (${rules.length})`, content)

  // Bind form buttons (re-bound each render)
  $('addRuleBtn')?.addEventListener('click', handleAddRule)
  $('saveBonusCapBtn')?.addEventListener('click', handleSaveBonusCap)
  $('removeBonusCapBtn')?.addEventListener('click', handleRemoveBonusCap)
}

function renderOutlets(outlets, error) {
  if (error) {
    $('sectionOutlets').innerHTML = sectionWrap('Outlets', '<p class="error-text">Could not load.</p>')
    return
  }

  const rows = outlets.length
    ? outlets.map(o => `
        <div class="dir-row" data-outlet-id="${escapeHtml(o.id)}">
          <div class="dir-info">
            <span class="dir-name">${escapeHtml(o.name)}</span>
          </div>
          <div class="dir-actions">
            <button class="btn-sm"
              data-rename-outlet="${escapeHtml(o.id)}"
              data-outlet-name="${escapeHtml(o.name)}">Rename</button>
            <button class="btn-danger-sm"
              data-delete-outlet="${escapeHtml(o.id)}">Remove</button>
          </div>
        </div>`).join('')
    : '<p class="empty">No outlets yet.</p>'

  const content = `
    <div class="dir-list" id="outletsList">${rows}</div>
    <div style="margin-top:10px">
      <button class="btn-sm" id="addOutletBtn">+ Add outlet</button>
    </div>
    <div class="status" id="outletsStatus"></div>
  `

  $('sectionOutlets').innerHTML = sectionWrap(`Outlets (${outlets.length})`, content)

  // Bind add outlet button (re-bound each render)
  $('addOutletBtn')?.addEventListener('click', handleAddOutletRow)
}

// ── HTML helpers ──────────────────────────────────────────────────────────────

function sectionWrap(title, content) {
  return `
    <div class="section-header">
      <span class="section-title">${escapeHtml(title)}</span>
    </div>
    ${content}
  `
}

function personRow(userId, actionEls) {
  const pid = escapeHtml(resolvePublicId(userId))
  const uid = escapeHtml(userId)
  return `
    <div class="dir-row">
      <div class="dir-info">
        <span class="dir-name">${pid}</span>
        <span class="dir-sub">${uid}</span>
      </div>
      <div class="dir-actions">${actionEls.join('')}</div>
    </div>`
}

// ── Event binding ─────────────────────────────────────────────────────────────

function bindEvents() {
  // Store list: card click → detail
  $('storeGrid')?.addEventListener('click', e => {
    const card = e.target.closest('[data-store-id]')
    if (!card) return
    showStoreDetail(card.dataset.storeId, card.dataset.storeName)
  })

  // Back button
  $('backBtn')?.addEventListener('click', showStoreList)

  // "+ New Store" toggle
  $('addStoreBtn')?.addEventListener('click', () => {
    $('createStoreForm').classList.remove('hidden')
    $('newStoreName').focus()
    $('addStoreBtn').classList.add('hidden')
  })

  $('cancelNewStoreBtn')?.addEventListener('click', cancelCreateStore)

  $('createStoreBtn')?.addEventListener('click', handleCreateStore)
  $('newStoreName')?.addEventListener('keydown', e => {
    if (e.key === 'Enter')  handleCreateStore()
    if (e.key === 'Escape') cancelCreateStore()
  })

  // All Users toggle
  $('toggleUsersBtn')?.addEventListener('click', () => {
    const section = $('usersSection')
    const hidden = section.classList.toggle('hidden')
    $('toggleUsersBtn').textContent = hidden ? 'All Users' : 'Hide Users'
  })

  // ── Store detail — managers ──────────────────────────────────────────────
  $('sectionManagers')?.addEventListener('click', async e => {
    const btn = e.target.closest('[data-demote-manager]')
    if (!btn) return
    if (!confirmStep(btn, 'Demote')) return
    btn.disabled = true
    const seq = loadSeq
    const { error } = await removeManager(btn.dataset.demoteManager, currentStoreId)
    if (seq !== loadSeq) return
    if (error) { btn.disabled = false; setStatus('storeHeaderStatus', error.message || 'Could not demote.', true); return }
    await loadAndRenderStoreDetail(currentStoreId)
  })

  // ── Store detail — staff ─────────────────────────────────────────────────
  $('sectionStaff')?.addEventListener('click', async e => {
    const promoteBtn = e.target.closest('[data-promote-to-mgr]')
    if (promoteBtn && promoteBtn.closest('#sectionStaff')) {
      promoteBtn.disabled = true
      const seq = loadSeq
      const { error } = await assignManager(promoteBtn.dataset.promoteToMgr, currentStoreId)
      if (seq !== loadSeq) return
      if (error) { promoteBtn.disabled = false; setStatus('storeHeaderStatus', error.message || 'Could not promote.', true); return }
      await loadAndRenderStoreDetail(currentStoreId)
      return
    }

    const demoteBtn = e.target.closest('[data-demote-staff]')
    if (!demoteBtn) return
    if (!confirmStep(demoteBtn, 'Demote')) return
    demoteBtn.disabled = true
    const seq = loadSeq
    const { error } = await removeStaffAdmin(demoteBtn.dataset.demoteStaff, currentStoreId)
    if (seq !== loadSeq) return
    if (error) { demoteBtn.disabled = false; setStatus('storeHeaderStatus', error.message || 'Could not demote.', true); return }
    await loadAndRenderStoreDetail(currentStoreId)
  })

  // ── Store detail — members ───────────────────────────────────────────────
  $('sectionMembers')?.addEventListener('click', async e => {
    const toStaffBtn = e.target.closest('[data-promote-to-staff]')
    if (toStaffBtn) {
      toStaffBtn.disabled = true
      const seq = loadSeq
      const { error } = await assignStaff(toStaffBtn.dataset.promoteToStaff, currentStoreId)
      if (seq !== loadSeq) return
      if (error) { toStaffBtn.disabled = false; setStatus('storeHeaderStatus', error.message || 'Could not promote.', true); return }
      await loadAndRenderStoreDetail(currentStoreId)
      return
    }

    const toMgrBtn = e.target.closest('[data-promote-to-mgr]')
    if (toMgrBtn && toMgrBtn.closest('#sectionMembers')) {
      toMgrBtn.disabled = true
      const seq = loadSeq
      const { error } = await assignManager(toMgrBtn.dataset.promoteToMgr, currentStoreId)
      if (seq !== loadSeq) return
      if (error) { toMgrBtn.disabled = false; setStatus('storeHeaderStatus', error.message || 'Could not promote.', true); return }
      await loadAndRenderStoreDetail(currentStoreId)
      return
    }

    const removeBtn = e.target.closest('[data-remove-member]')
    if (!removeBtn) return
    if (!confirmStep(removeBtn, 'Remove')) return
    removeBtn.disabled = true
    const seq = loadSeq
    const { error } = await removeCustomerFromStore(removeBtn.dataset.removeMember, currentStoreId)
    if (seq !== loadSeq) return
    if (error) { removeBtn.disabled = false; setStatus('storeHeaderStatus', error.message || 'Could not remove.', true); return }
    await loadAndRenderStoreDetail(currentStoreId)
  })

  // ── Store detail — rewards ───────────────────────────────────────────────
  $('sectionRewards')?.addEventListener('click', async e => {
    const deleteBtn = e.target.closest('[data-delete-rule]')
    if (deleteBtn) {
      deleteBtn.disabled = true
      const { error } = await deleteRewardRule(deleteBtn.dataset.deleteRule)
      if (error) { deleteBtn.disabled = false; setStatus('addRuleStatus', error.message || 'Could not delete.', true); return }
      const { data, error: re } = await loadRewardRules(currentStoreId)
      rulesLocal = data || []
      const cap = $('bonusCapInput')?.value
      renderRewards(rulesLocal, cap !== undefined ? (cap || null) : null, re)
      return
    }

    const moveBtn = e.target.closest('[data-move-rule]')
    if (moveBtn) {
      await handleMoveRule(moveBtn.dataset.moveRule, moveBtn.dataset.direction)
    }
  })

  // ── Store detail — outlets ───────────────────────────────────────────────
  $('sectionOutlets')?.addEventListener('click', async e => {
    const renameBtn = e.target.closest('[data-rename-outlet]')
    if (renameBtn) {
      showOutletInlineEdit(renameBtn.dataset.renameOutlet, renameBtn.dataset.outletName)
      return
    }

    const saveRename = e.target.closest('[data-save-outlet]')
    if (saveRename) {
      await handleSaveOutletRename(saveRename.dataset.saveOutlet)
      return
    }

    const cancelRename = e.target.closest('[data-cancel-outlet]')
    if (cancelRename) {
      renderOutlets(outletsLocal, null)
      return
    }

    const saveNew = e.target.closest('[data-save-new-outlet]')
    if (saveNew) {
      await handleSaveNewOutlet()
      return
    }

    const cancelNew = e.target.closest('[data-cancel-new-outlet]')
    if (cancelNew) {
      renderOutlets(outletsLocal, null)
      return
    }

    const deleteBtn = e.target.closest('[data-delete-outlet]')
    if (deleteBtn) {
      await handleDeleteOutlet(deleteBtn.dataset.deleteOutlet, deleteBtn)
    }
  })
}

// ── Create store ──────────────────────────────────────────────────────────────

function cancelCreateStore() {
  $('createStoreForm').classList.add('hidden')
  $('addStoreBtn').classList.remove('hidden')
  $('newStoreName').value = ''
  setStatus('createStoreStatus', '')
}

async function handleCreateStore() {
  const name = $('newStoreName').value.trim()
  if (!name) return
  const btn = $('createStoreBtn')
  btn.disabled = true
  setStatus('createStoreStatus', '')

  const { data, error } = await createStore(name)
  btn.disabled = false

  if (error || !data) {
    setStatus('createStoreStatus', error?.message || 'Could not create store.', true)
    return
  }

  allStores = [...allStores, { id: data.id, name: data.name, is_active: true, logo_path: null, logo_updated_at: null }]
  cancelCreateStore()
  await showStoreDetail(data.id, data.name)
}

// ── Store header actions ──────────────────────────────────────────────────────

async function handleSaveStoreName() {
  const input = $('storeNameInput')
  const name  = input?.value.trim()
  if (!name) return

  const btn = $('saveNameBtn')
  btn.disabled = true
  setStatus('storeHeaderStatus', '')

  const { data, error } = await updateStoreName(currentStoreId, name)
  btn.disabled = false

  if (error || !data) {
    setStatus('storeHeaderStatus', error?.message || 'Could not rename store.', true)
    return
  }

  allStores = allStores.map(s => s.id === currentStoreId ? { ...s, name: data.name } : s)
  currentStoreName = data.name

  // Update header in-place without reloading all sections
  const nameEl = $('storeDetailName')
  if (nameEl) nameEl.textContent = data.name
  $('storeNameDisplay').classList.remove('hidden')
  $('storeNameEditRow').classList.add('hidden')
  setStatus('storeHeaderStatus', '')
}

async function handleArchiveRestore() {
  const btn      = $('archiveRestoreBtn')
  const store    = allStores.find(s => s.id === currentStoreId)
  const archived = store?.is_active === false

  if (!archived && !confirmStep(btn, 'Archive')) return

  btn.disabled = true
  const { error } = archived
    ? await restoreStore(currentStoreId)
    : await archiveStore(currentStoreId)

  if (error) {
    btn.disabled = false
    btn.dataset.confirm = ''
    btn.textContent = archived ? 'Restore' : 'Archive'
    setStatus('storeHeaderStatus', error.message || 'Could not complete action.', true)
    return
  }

  allStores = allStores.map(s =>
    s.id === currentStoreId ? { ...s, is_active: archived, deleted_at: archived ? null : new Date().toISOString() } : s
  )

  // Re-render header with updated store state
  const freshStore = allStores.find(s => s.id === currentStoreId)
  renderStoreHeader(freshStore)
}

async function handleLogoUpload(e) {
  const file = e.target.files?.[0]
  if (!file || !currentStoreId) return
  e.target.value = ''

  setStatus('logoUploadStatus', 'Uploading…')

  try {
    const blob = await processLogoFile(file)
    const path = `stores/${currentStoreId}/logo.webp`

    const { error: uploadError } = await uploadStoreLogo(currentStoreId, blob)
    if (uploadError) { setStatus('logoUploadStatus', uploadError.message, true); return }

    const { error: rpcError } = await setStoreLogo(currentStoreId, path)
    if (rpcError) { setStatus('logoUploadStatus', rpcError.message, true); return }

    const updatedAt = new Date().toISOString()
    allStores = allStores.map(s =>
      s.id === currentStoreId ? { ...s, logo_path: path, logo_updated_at: updatedAt } : s
    )

    const freshStore = allStores.find(s => s.id === currentStoreId)
    renderStoreHeader(freshStore)
  } catch {
    setStatus('logoUploadStatus', 'Could not process image. Try a different file.', true)
  }
}

// ── Reward rules ──────────────────────────────────────────────────────────────

async function handleAddRule() {
  const label  = $('ruleLabel')?.value.trim()
  const points = parseInt($('rulePoints')?.value, 10)
  const kind   = $('ruleKind')?.value

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
  setStatus('addRuleStatus', '')

  const { error } = await insertRewardRule(
    currentStoreId,
    { label, points: effectivePoints, kind },
    rulesLocal.length + 1
  )

  if (error) {
    btn.disabled = false
    setStatus('addRuleStatus', error.message || 'Could not add rule.', true)
    return
  }

  const { data, error: re } = await loadRewardRules(currentStoreId)
  rulesLocal = data || []
  renderRewards(rulesLocal, $('bonusCapInput')?.value || null, re)
}

async function handleMoveRule(ruleId, direction) {
  const idx = rulesLocal.findIndex(r => r.id === ruleId)
  if (idx === -1) return
  const swapIdx = direction === 'up' ? idx - 1 : idx + 1
  if (swapIdx < 0 || swapIdx >= rulesLocal.length) return

  ;[rulesLocal[idx], rulesLocal[swapIdx]] = [rulesLocal[swapIdx], rulesLocal[idx]]
  rulesLocal.forEach((r, i) => { r.sort_order = i + 1 })
  renderRewards(rulesLocal, $('bonusCapInput')?.value || null, null)

  const [{ error: e1 }, { error: e2 }] = await Promise.all([
    updateRewardRuleOrder(rulesLocal[idx].id, rulesLocal[idx].sort_order),
    updateRewardRuleOrder(rulesLocal[swapIdx].id, rulesLocal[swapIdx].sort_order),
  ])

  if (e1 || e2) {
    const { data } = await loadRewardRules(currentStoreId)
    rulesLocal = data || []
    renderRewards(rulesLocal, $('bonusCapInput')?.value || null, e1 || e2)
  }
}

async function handleSaveBonusCap() {
  const val = parseInt($('bonusCapInput').value)
  if (!val || val < 1) { setStatus('bonusCapStatus', 'Enter a value of 1 or more.', true); return }

  const btn = $('saveBonusCapBtn')
  btn.disabled = true
  const { error } = await setBonusCap(currentStoreId, val)
  btn.disabled = false

  if (error) { setStatus('bonusCapStatus', error.message || 'Could not save cap.', true); return }
  setStatus('bonusCapStatus', `Cap set to ${val} pts.`)
}

async function handleRemoveBonusCap() {
  const btn = $('removeBonusCapBtn')
  btn.disabled = true
  const { error } = await setBonusCap(currentStoreId, null)
  btn.disabled = false

  if (error) { setStatus('bonusCapStatus', error.message || 'Could not remove cap.', true); return }
  $('bonusCapInput').value = ''
  setStatus('bonusCapStatus', 'Bonus cap removed.')
}

// ── Outlets ───────────────────────────────────────────────────────────────────

function handleAddOutletRow() {
  const list = $('outletsList')
  if (!list) return
  if (list.querySelector('[data-new-outlet-row]')) return  // prevent duplicates

  const row = document.createElement('div')
  row.className = 'inline-edit-row'
  row.dataset.newOutletRow = 'true'
  row.innerHTML = `
    <input class="input input-grow" placeholder="Outlet name…" />
    <button class="btn-sm" data-save-new-outlet>Save</button>
    <button class="btn-danger-sm" data-cancel-new-outlet>Cancel</button>
  `
  list.appendChild(row)
  row.querySelector('input')?.focus()
}

async function handleSaveNewOutlet() {
  const list  = $('outletsList')
  const row   = list?.querySelector('[data-new-outlet-row]')
  const input = row?.querySelector('input')
  const name  = input?.value.trim()
  if (!name) { renderOutlets(outletsLocal, null); return }

  const saveBtn = row?.querySelector('[data-save-new-outlet]')
  if (saveBtn) saveBtn.disabled = true

  const seq = loadSeq
  const { error } = await createOutlet(currentStoreId, name)
  if (seq !== loadSeq) return

  if (error) {
    if (saveBtn) saveBtn.disabled = false
    setStatus('outletsStatus', error.message || 'Could not create outlet.', true)
    return
  }

  const { data, error: oe } = await loadStoreOutlets(currentStoreId)
  outletsLocal = data || []
  renderOutlets(outletsLocal, oe)
}

function showOutletInlineEdit(outletId, currentName) {
  const list = $('outletsList')
  const row  = list?.querySelector(`[data-outlet-id="${CSS.escape(outletId)}"]`)
  if (!row) return
  row.outerHTML = `
    <div class="inline-edit-row" data-outlet-id="${escapeHtml(outletId)}">
      <input class="input input-grow"
             value="${escapeHtml(currentName)}"
             id="outlet-edit-${escapeHtml(outletId)}" />
      <button class="btn-sm" data-save-outlet="${escapeHtml(outletId)}">Save</button>
      <button class="btn-danger-sm" data-cancel-outlet="${escapeHtml(outletId)}">Cancel</button>
    </div>`
  $(`outlet-edit-${outletId}`)?.focus()
}

async function handleSaveOutletRename(outletId) {
  const input = $(`outlet-edit-${outletId}`)
  const name  = input?.value.trim()
  if (!name) { renderOutlets(outletsLocal, null); return }

  const saveBtn = $('outletsList')?.querySelector(`[data-save-outlet="${CSS.escape(outletId)}"]`)
  if (saveBtn) saveBtn.disabled = true

  const seq = loadSeq
  const { error } = await updateOutlet(outletId, name)
  if (seq !== loadSeq) return

  if (error) {
    if (saveBtn) saveBtn.disabled = false
    setStatus('outletsStatus', error.message || 'Could not rename outlet.', true)
    return
  }

  const { data, error: oe } = await loadStoreOutlets(currentStoreId)
  outletsLocal = data || []
  renderOutlets(outletsLocal, oe)
}

async function handleDeleteOutlet(outletId, btn) {
  if (!confirmStep(btn, 'Remove')) return
  btn.disabled = true

  const seq = loadSeq
  const { error } = await deleteOutlet(outletId)
  if (seq !== loadSeq) return

  if (error) {
    btn.disabled = false
    btn.dataset.confirm = ''
    btn.textContent = 'Remove'
    setStatus('outletsStatus', error.message || 'Could not delete outlet.', true)
    return
  }

  const { data, error: oe } = await loadStoreOutlets(currentStoreId)
  outletsLocal = data || []
  renderOutlets(outletsLocal, oe)
}

// ── Logo processing ───────────────────────────────────────────────────────────

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
      'image/webp', 0.82
    )
  })
}

// ── Utilities ─────────────────────────────────────────────────────────────────

function resolvePublicId(userId) {
  const u = allUsers.find(u => u.user_id === userId)
  return u?.public_id || userId
}

function setStatus(id, message, isError = false) {
  const el = $(id)
  if (!el) return
  el.textContent = message
  el.classList.toggle('error', isError)
}

// Double-confirm for destructive buttons.
// First call: shows "Sure?" and returns false. Second call: returns true.
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
  btn.dataset.confirm = ''
  return true
}

init()
