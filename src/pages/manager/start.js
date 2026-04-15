import { initAuth } from '../../services/auth.js'
import { approveApplicant, loadApplicants, loadManagedStores } from '../../services/applicants.js'
import { loadUserProfile } from '../../services/members.js'

let selectedStoreId = null

const $ = id => document.getElementById(id)
const escapeHtml = value => String(value ?? '')
  .replaceAll('&', '&amp;')
  .replaceAll('<', '&lt;')
  .replaceAll('>', '&gt;')
  .replaceAll('"', '&quot;')
  .replaceAll("'", '&#39;')
const toHumanId = (publicId, userId) => publicId || `USR-${String(userId || '').slice(0, 6).toUpperCase()}`

async function init() {
  try {
    const user = await initAuth()
    await renderManagerId(user?.id)
    await renderStores()
    bindEvents()
  } catch (err) {
    console.error(err)
    setStatus(err.message || 'Could not load manager tools.', true)
  }
}

async function renderManagerId(userId) {
  const idEl = $('myId')
  if (!idEl || !userId) return

  const profile = await loadUserProfile(userId)
  idEl.textContent = toHumanId(profile?.public_id, userId)
}

async function renderStores() {
  const list = $('storeList')
  const { data, error } = await loadManagedStores()

  if (error) throw error

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
      <button class="approve-btn" data-approve-user-id="${escapeHtml(applicant.user_id)}">Approve</button>
    </div>
  `).join('')
}

function bindEvents() {
  $('storeList')?.addEventListener('click', async event => {
    const button = event.target.closest('[data-store-id]')
    if (!button) return

    selectedStoreId = button.dataset.storeId
    document.querySelectorAll('[data-store-id]').forEach(node => {
      node.classList.toggle('selected', node === button)
    })
    $('selectedStore').textContent = button.querySelector('.pick-title')?.textContent || selectedStoreId
    setStatus('')
    try {
      await renderApplicants()
    } catch (err) {
      console.error(err)
      setStatus(err.message || 'Could not load applicants.', true)
    }
  })

  $('applicantList')?.addEventListener('click', async event => {
    const button = event.target.closest('[data-approve-user-id]')
    if (!button || !selectedStoreId) return

    const userId = button.dataset.approveUserId
    button.disabled = true
    button.textContent = 'Approving...'

    try {
      const { error } = await approveApplicant(userId, selectedStoreId)
      if (error) throw error

      setStatus('Applicant promoted to staff.')
      await renderApplicants()
    } catch (err) {
      console.error(err)
      setStatus(err.message || 'Could not approve applicant.', true)
      button.disabled = false
      button.textContent = 'Approve'
    }
  })
}

function setStatus(message, isError = false) {
  const status = $('status')
  if (!status) return

  status.textContent = message
  status.classList.toggle('error', isError)
}

init()
