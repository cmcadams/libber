import { captureError } from '../../lib/sentry.js'
import { initAuth } from '../../services/auth.js'
import { approveApplicant, demoteStaff, loadManagedStores, loadStaff } from '../../services/applicants.js'
import { loadUserProfile, loadMembers } from '../../services/members.js'
import { escapeHtml } from '../../lib/escape.js'
import { state } from '../../state/state.js'
import { $, $$ } from '../../lib/dom.js'
import { toHumanId } from '../../lib/format.js'

if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('/apps/staff/sw.js').catch(() => {})
}

let selectedStoreId = null
let staffIds = new Set()
let loadToken = 0

async function init() {
  try {
    const user = await initAuth()
    await renderManagerId(user?.id)
    const { data: managed } = await loadManagedStores()
    renderStores(managed ?? [])
    bindEvents()
  } catch (err) {
    captureError(err)
    $('membersPanel').style.display = ''
    setStatus(err.message || 'Could not load manager tools.', true)
  }
}

async function renderManagerId(userId) {
  const idEl = $('myId')
  if (!idEl || !userId) return
  const { data: profile } = await loadUserProfile(userId)
  idEl.textContent = toHumanId(profile?.public_id, userId)
}

function renderStores(data) {
  const list = $('storeList')
  if (!data?.length) {
    list.innerHTML = '<p class="empty">No managed stores found</p>'
    return
  }
  list.innerHTML = data.map(store => `
    <button class="pick-card" data-store-id="${escapeHtml(store.store_id)}">
      ${escapeHtml(store.stores?.name || 'Untitled store')}
    </button>
  `).join('')
}

async function loadStoreData(storeId) {
  const token = ++loadToken
  const [membersResult, staffResult] = await Promise.all([
    loadMembers(storeId),
    loadStaff(storeId)
  ])
  if (token !== loadToken) return
  if (membersResult.error) throw membersResult.error
  if (staffResult.error) throw staffResult.error
  staffIds = new Set((staffResult.data || []).map(s => s.user_id))
  renderMembers()
}

function renderMembers() {
  const list = $('memberList')
  const members = state.members || []

  if (!members.length) {
    list.innerHTML = '<p class="empty">No members yet</p>'
    return
  }

  const sorted = [...members].sort((a, b) => {
    const aRank = staffIds.has(a.user_id) ? 0 : 1
    const bRank = staffIds.has(b.user_id) ? 0 : 1
    if (aRank !== bRank) return aRank - bRank
    return a.public_id.localeCompare(b.public_id)
  })

  list.innerHTML = sorted.map(m => {
    const isStaff = staffIds.has(m.user_id)
    return `
      <div class="member-card${isStaff ? ' is-staff' : ''}" data-user-id="${escapeHtml(m.user_id)}">
        <div class="member-info">
          <span class="member-id">${escapeHtml(m.public_id)}</span>
          ${isStaff ? '<span class="staff-badge">Staff</span>' : ''}
        </div>
        <div>
          ${isStaff
            ? `<button class="demote-btn" data-demote-user-id="${escapeHtml(m.user_id)}">Demote</button>`
            : `<button class="promote-btn" data-promote-user-id="${escapeHtml(m.user_id)}">Promote to staff</button>`
          }
        </div>
      </div>`
  }).join('')
}

function bindEvents() {
  $('storeList')?.addEventListener('click', async event => {
    const button = event.target.closest('[data-store-id]')
    if (!button) return

    selectedStoreId = button.dataset.storeId
    const storeName = button.textContent.trim()
    $$('[data-store-id]').forEach(node => node.classList.toggle('selected', node === button))
    $('selectedStore').textContent = storeName
    $('membersPanel').style.display = ''
    setStatus('')

    try {
      await loadStoreData(selectedStoreId)
    } catch (err) {
      captureError(err)
      setStatus(err.message || 'Could not load store data.', true)
    }
  })

  $('memberList')?.addEventListener('click', async event => {
    const promoteBtn = event.target.closest('[data-promote-user-id]')
    if (promoteBtn && selectedStoreId) {
      const userId = promoteBtn.dataset.promoteUserId
      promoteBtn.disabled = true
      promoteBtn.textContent = 'Promoting...'
      try {
        const { error } = await approveApplicant(userId, selectedStoreId)
        if (error) throw error
        staffIds.add(userId)
        renderMembers()
        setStatus('Promoted to staff.')
      } catch (err) {
        captureError(err)
        setStatus(err.message || 'Could not promote.', true)
        promoteBtn.disabled = false
        promoteBtn.textContent = 'Promote to staff'
      }
      return
    }

    const demoteBtn = event.target.closest('[data-demote-user-id]')
    if (demoteBtn && selectedStoreId) {
      const userId = demoteBtn.dataset.demoteUserId
      demoteBtn.disabled = true
      demoteBtn.textContent = 'Demoting...'
      try {
        const { error } = await demoteStaff(userId, selectedStoreId)
        if (error) throw error
        staffIds.delete(userId)
        renderMembers()
        setStatus('Demoted to customer.')
      } catch (err) {
        captureError(err)
        setStatus(err.message || 'Could not demote.', true)
        demoteBtn.disabled = false
        demoteBtn.textContent = 'Demote'
      }
    }
  })

  $('staffPageBtn')?.addEventListener('click', () => { window.location.href = '/apps/staff/' })

  $('refreshBtn')?.addEventListener('click', async () => {
    if (!selectedStoreId) return
    const btn = $('refreshBtn')
    btn.classList.add('loading')
    btn.disabled = true
    try {
      await loadStoreData(selectedStoreId)
    } catch (err) {
      captureError(err)
      setStatus(err.message || 'Could not refresh.', true)
    }
    btn.classList.remove('loading')
    btn.disabled = false
  })
}

function setStatus(message, isError = false) {
  const status = $('status')
  if (!status) return
  status.textContent = message
  status.classList.toggle('error', isError)
}

init()
