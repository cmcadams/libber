import { state } from '../state/state.js'
import { awardPoints, adjustPoints } from '../services/members.js'
import { escapeHtml } from '../lib/escape.js'
import { $ } from '../lib/dom.js'

let selectedMember = null
let bonusPts       = null
let bonusReason    = null
let _reRenderTimer = null

function scheduleReRender() {
  clearTimeout(_reRenderTimer)
  _reRenderTimer = setTimeout(() => {
    renderRuleButtons()
    renderCustomers()
  }, 1500)
}

export function renderCustomers() {
  const container = $('customerList')
  if (!container) return

  const members = state.members || []
  const showSearch = members.length >= 10
  const searchEl = $('search')
  if (searchEl) searchEl.style.display = showSearch ? '' : 'none'

  const query = (showSearch ? searchEl?.value || '' : '').toUpperCase().replace(/[-\s]/g, '').trim()

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

  search?.focus()
  search?.addEventListener('input', () => renderCustomers())

  $('customerList')?.addEventListener('click', e => {
    const row = e.target.closest('.customer-row')
    if (!row) return
    const member = (state.members || []).find(m => m.user_id === row.dataset.userId)
    if (!member) return
    openPanel(member)
  })

  $('closeBtn')?.addEventListener('click', closePanel)
  overlay?.addEventListener('click', e => { if (e.target === overlay) closePanel() })

  $('quickBtns')?.addEventListener('click', e => {
    const btn = e.target.closest('.quick-btn')
    if (!btn || btn.disabled || !selectedMember) return
    handleQuickAward(btn)
  })

  $('bonusReasonBtns')?.addEventListener('click', e => {
    const btn = e.target.closest('.bonus-reason-btn')
    if (!btn) return
    $('bonusReasonBtns').querySelectorAll('.bonus-reason-btn').forEach(b => b.classList.remove('selected'))
    btn.classList.add('selected')
    bonusReason = btn.dataset.reason
    updateAwardBtn()
  })

  $('bonusBtns')?.addEventListener('click', e => {
    const btn = e.target.closest('.bonus-btn')
    if (!btn) return
    $('bonusBtns').querySelectorAll('.bonus-btn').forEach(b => b.classList.remove('selected'))
    btn.classList.add('selected')
    bonusPts = parseInt(btn.dataset.pts)
    updateAwardBtn()
  })

  $('awardBtn')?.addEventListener('click', handleBonusAward)

  $('adjustInput')?.addEventListener('input', updateAdjustBtn)
  $('adjustReason')?.addEventListener('input', updateAdjustBtn)
  $('adjustBtn')?.addEventListener('click', handleAdjust)

  $('redeemBtns')?.addEventListener('click', e => {
    const btn = e.target.closest('.redeem-btn')
    if (!btn || btn.disabled || !selectedMember) return
    handleRedeem(btn)
  })
}

function renderRuleButtons() {
  const rules = state.rewardRules || []
  const quickRules        = rules.filter(r => r.kind === 'award')
  const redeemRules       = rules.filter(r => r.kind === 'redeem')
  const bonusReasonRules  = rules.filter(r => r.kind === 'bonus_reason')
  const bonusAmountRules  = rules.filter(r => r.kind === 'bonus_amount')
  const balance = selectedMember?.balance ?? 0

  if ($('quickSection')) $('quickSection').style.display = quickRules.length ? '' : 'none'
  if ($('sectionDivider')) $('sectionDivider').style.display = quickRules.length ? '' : 'none'
  if ($('redeemSection')) $('redeemSection').style.display = redeemRules.length ? '' : 'none'
  if ($('redeemDivider')) $('redeemDivider').style.display = redeemRules.length ? '' : 'none'

  $('quickBtns').innerHTML = quickRules.map(r => `
    <button class="quick-btn" data-pts="${r.points}" data-label="${escapeHtml(r.label)}" data-rule-id="${escapeHtml(r.id)}">
      <span class="btn-label">${escapeHtml(r.label)}</span>
      <span class="btn-pts">+${r.points} pts</span>
    </button>
  `).join('')

  $('bonusReasonBtns').innerHTML = bonusReasonRules.map(r => `
    <button class="bonus-reason-btn" data-reason="${escapeHtml(r.label)}">${escapeHtml(r.label)}</button>
  `).join('')

  if (bonusReason !== null) {
    $('bonusReasonBtns').querySelectorAll('.bonus-reason-btn').forEach(b => {
      b.classList.toggle('selected', b.dataset.reason === bonusReason)
    })
  }

  const cap = state.bonusCap
  const validAmounts = cap != null
    ? bonusAmountRules.filter(r => r.points <= cap)
    : bonusAmountRules

  $('bonusBtns').innerHTML = validAmounts.length
    ? validAmounts.map(r => `<button class="bonus-btn" data-pts="${r.points}">+${r.points}</button>`).join('')
    : `<p style="font-size:13px;color:var(--text-hint);padding:4px 0">${
        bonusAmountRules.length ? `No amounts within cap (${cap} pts)` : 'No bonus amounts configured'
      }</p>`

  if (bonusPts !== null) {
    $('bonusBtns').querySelectorAll('.bonus-btn').forEach(b => {
      if (parseInt(b.dataset.pts) === bonusPts) b.classList.add('selected')
    })
  }

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
  bonusPts       = null
  bonusReason    = null

  $('panelId').textContent      = member.public_id
  $('panelBalance').textContent = member.balance
  $('adjustInput').value        = ''
  $('adjustReason').value       = 'Adjustment'
  $('status').textContent       = ''
  $('awardBtn').disabled        = true
  $('awardBtn').textContent     = 'Award bonus'
  $('awardBtn').className       = 'award-btn'
  $('adjustBtn').disabled       = true
  $('adjustBtn').textContent    = 'Apply adjustment'
  $('adjustBtn').className      = 'award-btn'

  renderRuleButtons()
  $('overlay').classList.add('open')
}

function closePanel() {
  $('overlay').classList.remove('open')
  selectedMember = null
  bonusPts       = null
  bonusReason    = null
}

async function handleQuickAward(btn) {
  if (!selectedMember || !state.selectedStoreId) return
  const pts = parseInt(btn.dataset.pts)

  btn.disabled = true
  try {
    await awardPoints(selectedMember.user_id, state.selectedStoreId, pts, btn.dataset.label, btn.dataset.ruleId)
    selectedMember.balance += pts
    $('panelBalance').textContent = selectedMember.balance
    btn.classList.add('done')
    btn.querySelector('.btn-label').textContent = 'awarded'
    btn.querySelector('.btn-pts').textContent   = `+${pts} pts`
    scheduleReRender()
  } catch (err) {
    btn.disabled = false
    setStatus(err.message || 'Could not award points.')
  }
}

async function handleBonusAward() {
  if (!selectedMember || !bonusPts || !bonusReason || !state.selectedStoreId) return

  $('awardBtn').disabled = true
  try {
    await awardPoints(selectedMember.user_id, state.selectedStoreId, bonusPts, bonusReason)
    selectedMember.balance += bonusPts
    $('panelBalance').textContent = selectedMember.balance
    $('awardBtn').textContent     = `+${bonusPts} pts awarded`
    $('awardBtn').className       = 'award-btn success'
    bonusPts    = null
    bonusReason = null
    $('bonusBtns').querySelectorAll('.bonus-btn').forEach(b => b.classList.remove('selected'))
    $('bonusReasonBtns').querySelectorAll('.bonus-reason-btn').forEach(b => b.classList.remove('selected'))
    scheduleReRender()
    setTimeout(() => {
      $('awardBtn').textContent = 'Award bonus'
      $('awardBtn').className   = 'award-btn'
      $('awardBtn').disabled    = true
    }, 1500)
  } catch (err) {
    $('awardBtn').disabled = false
    setStatus(err.message || 'Could not award bonus.')
  }
}

async function handleAdjust() {
  if (!selectedMember || !state.selectedStoreId) return
  const pts    = parseInt($('adjustInput').value)
  const reason = $('adjustReason').value.trim()
  if (!Number.isInteger(pts) || pts === 0 || !reason) return

  const btn = $('adjustBtn')
  btn.disabled = true
  try {
    await adjustPoints(selectedMember.user_id, state.selectedStoreId, pts, reason)
    selectedMember.balance += pts
    $('panelBalance').textContent = selectedMember.balance
    btn.textContent               = pts > 0 ? `+${pts} pts applied` : `${pts} pts applied`
    btn.className                 = 'award-btn success'
    $('adjustInput').value        = ''
    scheduleReRender()
    setTimeout(() => {
      btn.textContent = 'Apply adjustment'
      btn.className   = 'award-btn'
      updateAdjustBtn()
    }, 1500)
  } catch (err) {
    btn.disabled = false
    setStatus(err.message || 'Could not apply adjustment.')
  }
}

async function handleRedeem(btn) {
  if (!selectedMember || !state.selectedStoreId) return
  const pts   = parseInt(btn.dataset.pts)
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
    btn.querySelector('.redeem-btn-cost').textContent  = `−${pts} pts`
    scheduleReRender()
  } catch (err) {
    btn.disabled = false
    setStatus(err.message || 'Could not redeem.')
  }
}

function updateAwardBtn() {
  $('awardBtn').disabled = !(bonusReason !== null && bonusPts !== null)
}

function updateAdjustBtn() {
  const pts    = parseInt($('adjustInput').value)
  const reason = ($('adjustReason').value || '').trim()
  $('adjustBtn').disabled = !(Number.isInteger(pts) && pts !== 0 && reason.length > 0)
}

function setStatus(msg) {
  $('status').textContent = msg
  setTimeout(() => { $('status').textContent = '' }, 3000)
}
