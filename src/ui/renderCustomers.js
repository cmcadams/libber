import { state } from '../state/state.js'
import { awardPoints } from '../services/members.js'
import { escapeHtml } from '../lib/escape.js'

let selectedMember = null
let bonusPts = null

const $ = id => document.getElementById(id)

export function renderCustomers() {
  const container = $('customerList')
  if (!container) return

  const members = state.members || []
  const query = ($('search')?.value || '').toUpperCase().replace(/[-\s]/g, '').trim()

  const filtered = query
    ? members.filter(m => m.public_id.replace(/[-\s]/g, '').includes(query))
    : members

  $('memberCount').textContent = `${filtered.length} of ${members.length} members`

  if (!filtered.length) {
    container.innerHTML = '<div class="empty">No customers found</div>'
    return
  }

  container.innerHTML = filtered.map(m => `
    <div class="customer-row" data-user-id="${escapeHtml(m.user_id)}">
      <span class="cust-id">${escapeHtml(m.public_id)}</span>
      <span class="cust-pts"><strong>${m.balance}</strong> pts</span>
    </div>
  `).join('')
}

export function initCustomerHandlers() {
  const overlay = $('overlay')
  const search = $('search')

  // auto-focus search
  search?.focus()

  // filter on input
  search?.addEventListener('input', () => renderCustomers())

  // open panel on row click (delegated)
  $('customerList')?.addEventListener('click', e => {
    const row = e.target.closest('.customer-row')
    if (!row) return
    const member = (state.members || []).find(m => m.user_id === row.dataset.userId)
    if (!member) return
    openPanel(member)
  })

  // close panel
  $('closeBtn')?.addEventListener('click', closePanel)
  overlay?.addEventListener('click', e => { if (e.target === overlay) closePanel() })

  // quick award buttons (delegated)
  $('quickBtns')?.addEventListener('click', e => {
    const btn = e.target.closest('.quick-btn')
    if (!btn || !selectedMember) return
    handleQuickAward(btn)
  })

  // bonus point selection (delegated)
  $('bonusBtns')?.addEventListener('click', e => {
    const btn = e.target.closest('.bonus-btn')
    if (!btn) return
    document.querySelectorAll('.bonus-btn').forEach(b => b.classList.remove('selected'))
    btn.classList.add('selected')
    bonusPts = parseInt(btn.dataset.pts)
    updateAwardBtn()
  })

  // redeem (delegated)
  $('redeemBtns')?.addEventListener('click', e => {
    const btn = e.target.closest('.redeem-btn')
    if (!btn || !selectedMember) return
    handleRedeem(btn)
  })

  // reason input
  $('reasonInput')?.addEventListener('input', updateAwardBtn)

  // award bonus button
  $('awardBtn')?.addEventListener('click', handleBonusAward)
}

const BONUS_AMOUNTS = [1, 5, 10, 25]

function renderRuleButtons() {
  const rules = state.rewardRules || []
  const quickRules = rules.filter(r => r.kind === 'award')
  const redeemRules = rules.filter(r => r.kind === 'redeem')
  const balance = selectedMember?.balance ?? 0

  if ($('quickSection')) $('quickSection').style.display = quickRules.length ? '' : 'none'
  if ($('sectionDivider')) $('sectionDivider').style.display = quickRules.length ? '' : 'none'
  if ($('redeemSection')) $('redeemSection').style.display = redeemRules.length ? '' : 'none'
  if ($('redeemDivider')) $('redeemDivider').style.display = redeemRules.length ? '' : 'none'

  $('quickBtns').innerHTML = quickRules.map(r => `
    <button class="quick-btn" data-pts="${r.points}" data-label="${escapeHtml(r.label)}">
      <span class="btn-label">${escapeHtml(r.label)}</span>
      <span class="btn-pts">+${r.points} pts</span>
    </button>
  `).join('')

  $('bonusBtns').innerHTML = BONUS_AMOUNTS.map(pts => `
    <button class="bonus-btn" data-pts="${pts}">+${pts}</button>
  `).join('')

  $('redeemBtns').innerHTML = redeemRules.map(r => `
    <button class="redeem-btn" data-pts="${r.points}" data-label="${escapeHtml(r.label)}"
      ${r.points > balance ? 'disabled' : ''}>
      <span class="redeem-btn-label">${escapeHtml(r.label)}</span>
      <span class="redeem-btn-cost">−${r.points} pts</span>
    </button>
  `).join('')
}

function openPanel(member) {
  selectedMember = member
  bonusPts = null

  $('panelId').textContent = member.public_id
  $('panelBalance').textContent = member.balance
  $('reasonInput').value = ''
  $('status').textContent = ''
  $('awardBtn').disabled = true
  $('awardBtn').textContent = 'Award bonus'
  $('awardBtn').className = 'award-btn'

  renderRuleButtons()

  $('overlay').classList.add('open')
}

function closePanel() {
  $('overlay').classList.remove('open')
  selectedMember = null
  bonusPts = null
}

async function handleQuickAward(btn) {
  if (!selectedMember || !state.selectedStoreId) return
  const pts = parseInt(btn.dataset.pts)

  btn.disabled = true
  try {
    await awardPoints(selectedMember.user_id, state.selectedStoreId, pts, btn.dataset.label)
    selectedMember.balance += pts
    $('panelBalance').textContent = selectedMember.balance
    btn.classList.add('done')
    btn.querySelector('.btn-label').textContent = 'awarded'
    btn.querySelector('.btn-pts').textContent = `+${pts} pts`
    setTimeout(() => {
      btn.classList.remove('done')
      btn.querySelector('.btn-label').textContent = btn.dataset.label
      btn.querySelector('.btn-pts').textContent = `+${pts} pts`
      btn.disabled = false
      renderCustomers()
    }, 1500)
  } catch (err) {
    btn.disabled = false
    setStatus('Could not award points. Try again.')
  }
}

async function handleBonusAward() {
  if (!selectedMember || !bonusPts || !state.selectedStoreId) return
  const reason = $('reasonInput').value.trim()
  if (!reason) return

  $('awardBtn').disabled = true
  try {
    await awardPoints(selectedMember.user_id, state.selectedStoreId, bonusPts, reason)
    selectedMember.balance += bonusPts
    $('panelBalance').textContent = selectedMember.balance
    $('awardBtn').textContent = `+${bonusPts} pts awarded`
    $('awardBtn').className = 'award-btn success'
    bonusPts = null
    $('reasonInput').value = ''
    document.querySelectorAll('.bonus-btn').forEach(b => b.classList.remove('selected'))
    setTimeout(() => {
      $('awardBtn').textContent = 'Award bonus'
      $('awardBtn').className = 'award-btn'
      $('awardBtn').disabled = true
      renderCustomers()
    }, 1500)
  } catch (err) {
    $('awardBtn').disabled = false
    setStatus('Could not award bonus. Try again.')
  }
}

async function handleRedeem(btn) {
  if (!selectedMember || !state.selectedStoreId) return
  const pts = parseInt(btn.dataset.pts)
  const label = btn.dataset.label

  if (selectedMember.balance < pts) {
    setStatus('Not enough points.')
    return
  }

  btn.disabled = true
  try {
    await awardPoints(selectedMember.user_id, state.selectedStoreId, -pts, label)
    selectedMember.balance -= pts
    $('panelBalance').textContent = selectedMember.balance
    btn.classList.add('done')
    btn.querySelector('.redeem-btn-label').textContent = 'Redeemed'
    btn.querySelector('.redeem-btn-cost').textContent = `−${pts} pts`
    setTimeout(() => {
      btn.classList.remove('done')
      btn.querySelector('.redeem-btn-label').textContent = label
      btn.querySelector('.redeem-btn-cost').textContent = `−${pts} pts`
      btn.disabled = selectedMember.balance < pts
      renderCustomers()
    }, 1500)
  } catch (err) {
    btn.disabled = false
    setStatus('Could not redeem. Try again.')
  }
}

function updateAwardBtn() {
  const hasReason = $('reasonInput').value.trim().length > 0
  $('awardBtn').disabled = !(hasReason && bonusPts !== null)
}

function setStatus(msg) {
  $('status').textContent = msg
  setTimeout(() => { $('status').textContent = '' }, 3000)
}
