import { initAuth } from '../../services/auth.js'
import { approveApplicant, demoteStaff, loadApplicants, loadManagedStores, loadStaff, rejectApplicant, applyForManager, loadMyManagerApplications } from '../../services/applicants.js'
import { loadUserProfile } from '../../services/members.js'
import { getStores } from '../../services/stores.js'
import { saveSelectedStore } from '../../lib/storage.js'
import { escapeHtml } from '../../lib/escape.js'
import { $, $$ } from '../../lib/dom.js'
import { toHumanId } from '../../lib/format.js'

let selectedStoreId = null
let selectedApplyStoreId = null
let pendingManagerStoreIds = new Set()
let managedStoreIds = new Set()

async function init() {
  try {
    const user = await initAuth()
    await renderManagerId(user?.id)

    const [{ data: managed }, { data: allStores }, { data: myApps }] = await Promise.all([
      loadManagedStores(),
      getStores(),
      loadMyManagerApplications(user?.id)
    ])

    managedStoreIds = new Set((managed ?? []).map(m => m.store_id))
    pendingManagerStoreIds = new Set((myApps ?? []).map(a => a.store_id))

    renderStores(managed ?? [])
    renderApplyStores(allStores ?? [])
    bindEvents()
  } catch (err) {
    console.error(err)
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
      <span class="pick-title">${escapeHtml(store.stores?.name || 'Untitled store')}</span>
      <span class="pick-sub">${escapeHtml(store.store_id)}</span>
    </button>
  `).join('')
}

function renderApplyStores(allStores) {
  const list = $('applyStoreList')
  const available = allStores.filter(s => !managedStoreIds.has(s.id))
  if (!available.length) {
    list.innerHTML = '<p class="empty">No stores available</p>'
    return
  }
  list.innerHTML = available.map(store => `
    <button class="pick-card" data-apply-store-id="${escapeHtml(store.id)}">
      <span class="pick-title">${escapeHtml(store.name || 'Untitled store')}</span>
      <span class="pick-sub">${escapeHtml(store.id)}</span>
    </button>
  `).join('')
}

async function renderStaff() {
  const list = $('staffList')
  const label = $('selectedStoreStaff')

  if (!selectedStoreId) {
    list.innerHTML = '<p class="empty">Pick a store to see staff</p>'
    if (label) label.textContent = 'None selected'
    return
  }

  if (label) label.textContent = $('selectedStore').textContent

  const { data, error } = await loadStaff(selectedStoreId)
  if (error) throw error

  if (!data?.length) {
    list.innerHTML = '<p class="empty">No staff yet</p>'
    return
  }

  list.innerHTML = data.map(member => `
    <div class="staff-card">
      <div>
        <div class="pick-title">${escapeHtml(toHumanId(member.public_id, member.user_id))}</div>
        <div class="pick-sub">${escapeHtml(member.user_id)}</div>
      </div>
      <button class="remove-btn" data-remove-user-id="${escapeHtml(member.user_id)}">Remove</button>
    </div>
  `).join('')
}

async function renderApplicants() {
  const list = $('applicantList')

  if (!selectedStoreId) {
    list.innerHTML = '<p class="empty">Pick a store to see applicants</p>'
    return
  }

  const { data, error } = await loadApplicants(selectedStoreId)
  if (error) throw error

  if (!data?.length) {
    list.innerHTML = '<p class="empty">No applicants yet</p>'
    return
  }

  list.innerHTML = data.map(applicant => `
    <div class="applicant-card" data-user-id="${escapeHtml(applicant.user_id)}">
      <div>
        <div class="pick-title">${escapeHtml(toHumanId(applicant.public_id, applicant.user_id))}</div>
        <div class="pick-sub">Internal: ${escapeHtml(applicant.user_id)}</div>
      </div>
      <div class="applicant-actions">
        <button class="approve-btn" data-approve-user-id="${escapeHtml(applicant.user_id)}">Approve</button>
        <button class="reject-btn" data-reject-user-id="${escapeHtml(applicant.user_id)}">Reject</button>
      </div>
    </div>
  `).join('')
}

function updateApplyButton() {
  const button = $('applyManagerBtn')
  if (!button) return

  if (!selectedApplyStoreId) {
    button.textContent = 'Apply'
    button.disabled = true
    return
  }

  if (pendingManagerStoreIds.has(selectedApplyStoreId)) {
    button.textContent = 'Pending approval'
    button.disabled = true
    setApplyStatus('Your application is waiting for admin approval.')
    return
  }

  button.textContent = 'Apply'
  button.disabled = false
}

function bindEvents() {
  $('storeList')?.addEventListener('click', async event => {
    const button = event.target.closest('[data-store-id]')
    if (!button) return

    selectedStoreId = button.dataset.storeId
    const storeName = button.querySelector('.pick-title')?.textContent || selectedStoreId
    saveSelectedStore(selectedStoreId, storeName)
    $$('[data-store-id]').forEach(node => {
      node.classList.toggle('selected', node === button)
    })
    $('selectedStore').textContent = storeName
    setStatus('')
    try {
      await Promise.all([renderApplicants(), renderStaff()])
    } catch (err) {
      console.error(err)
      setStatus(err.message || 'Could not load store data.', true)
    }
  })

  $('staffList')?.addEventListener('click', async event => {
    const button = event.target.closest('[data-remove-user-id]')
    if (!button || !selectedStoreId) return

    const userId = button.dataset.removeUserId
    button.disabled = true
    button.textContent = 'Removing...'

    try {
      const { error } = await demoteStaff(userId, selectedStoreId)
      if (error) throw error
      setStatus('Staff member removed.')
      await renderStaff()
    } catch (err) {
      console.error(err)
      setStatus(err.message || 'Could not remove staff member.', true)
      button.disabled = false
      button.textContent = 'Remove'
    }
  })

  $('applicantList')?.addEventListener('click', async event => {
    const approveBtn = event.target.closest('[data-approve-user-id]')
    if (approveBtn && selectedStoreId) {
      const userId = approveBtn.dataset.approveUserId
      approveBtn.disabled = true
      approveBtn.textContent = 'Approving...'
      try {
        const { error } = await approveApplicant(userId, selectedStoreId)
        if (error) throw error
        setStatus('Applicant promoted to staff.')
        await Promise.all([renderApplicants(), renderStaff()])
      } catch (err) {
        console.error(err)
        setStatus(err.message || 'Could not approve applicant.', true)
        approveBtn.disabled = false
        approveBtn.textContent = 'Approve'
      }
      return
    }

    const rejectBtn = event.target.closest('[data-reject-user-id]')
    if (rejectBtn && selectedStoreId) {
      const userId = rejectBtn.dataset.rejectUserId
      rejectBtn.disabled = true
      rejectBtn.textContent = 'Rejecting...'
      try {
        const { error } = await rejectApplicant(userId, selectedStoreId)
        if (error) throw error
        setStatus('Applicant rejected.')
        await renderApplicants()
      } catch (err) {
        console.error(err)
        setStatus(err.message || 'Could not reject applicant.', true)
        rejectBtn.disabled = false
        rejectBtn.textContent = 'Reject'
      }
    }
  })

  $('applyStoreList')?.addEventListener('click', event => {
    const button = event.target.closest('[data-apply-store-id]')
    if (!button) return

    selectedApplyStoreId = button.dataset.applyStoreId
    $$('[data-apply-store-id]').forEach(node => {
      node.classList.toggle('selected', node === button)
    })
    $('applySelectedStore').textContent = button.querySelector('.pick-title')?.textContent || selectedApplyStoreId
    setApplyStatus('')
    updateApplyButton()
  })

  $('applyManagerBtn')?.addEventListener('click', handleApply)

  $('refreshBtn')?.addEventListener('click', async () => {
    if (!selectedStoreId) return
    const btn = $('refreshBtn')
    btn.classList.add('loading')
    btn.disabled = true
    try {
      await Promise.all([renderApplicants(), renderStaff()])
    } catch (err) {
      console.error(err)
      setStatus(err.message || 'Could not refresh.', true)
    }
    btn.classList.remove('loading')
    btn.disabled = false
  })
}

async function handleApply() {
  if (!selectedApplyStoreId) return

  const button = $('applyManagerBtn')
  button.disabled = true
  button.textContent = 'Applying...'

  try {
    const { error } = await applyForManager(selectedApplyStoreId)
    if (error) throw error

    pendingManagerStoreIds.add(selectedApplyStoreId)
    updateApplyButton()
    setApplyStatus('Applied. Ask the admin to approve you.')
  } catch (err) {
    console.error(err)
    setApplyStatus(err.message || 'Could not apply.', true)
    updateApplyButton()
  }
}

function setStatus(message, isError = false) {
  const status = $('status')
  if (!status) return
  status.textContent = message
  status.classList.toggle('error', isError)
}

function setApplyStatus(message, isError = false) {
  const status = $('applyStatus')
  if (!status) return
  status.textContent = message
  status.classList.toggle('error', isError)
}

init()
