import { state } from '../state/state.js'
import { awardPoints, adjustPoints, loadMemberRecentTransactions } from '../services/members.js'
import { escapeHtml } from '../lib/escape.js'
import { $ } from '../lib/dom.js'
import { captureError } from '../lib/sentry.js'
import { showConfirm, showAlert } from '../lib/confirm.js'
import { formatShortDate } from '../lib/format.js'

let selectedMember  = null
let bonusPts        = null
let bonusReason     = null
let adjustAmount    = ''
let adjustDirection = null
let _reRenderTimer  = null
let _statusTimer    = null
let _historyTrigger = null

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

  const members    = state.members || []
  const showSearch = members.length >= 10
  const searchEl   = $('search')
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
      <div class="cust-right">
        <span class="cust-pts"><strong>${m.balance}</strong> pts</span>
        <button class="history-btn" data-user-id="${escapeHtml(m.user_id)}"
          aria-label="View transaction history for ${escapeHtml(m.public_id)}"
          title="View last 5 transactions">History</button>
      </div>
    </div>
  `).join('')
}

export function initCustomerHandlers() {
  const overlay = $('overlay')
  const search  = $('search')

  search?.addEventListener('input', () => renderCustomers())

  $('customerList')?.addEventListener('click', e => {
    // History button takes priority — do not open the member panel
    const histBtn = e.target.closest('.history-btn')
    if (histBtn) {
      const member = (state.members || []).find(m => m.user_id === histBtn.dataset.userId)
      if (member) handleViewHistory(member, histBtn)
      return
    }
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
    const alreadySelected = btn.classList.contains('selected')
    $('bonusReasonBtns').querySelectorAll('.bonus-reason-btn').forEach(b => b.classList.remove('selected'))
    if (alreadySelected) {
      bonusReason = null
    } else {
      btn.classList.add('selected')
      bonusReason = btn.dataset.reason
    }
    updateBonusState()
  })

  $('bonusBtns')?.addEventListener('click', e => {
    const btn = e.target.closest('.bonus-btn')
    if (!btn) return
    const alreadySelected = btn.classList.contains('selected')
    $('bonusBtns').querySelectorAll('.bonus-btn').forEach(b => b.classList.remove('selected'))
    if (alreadySelected) {
      bonusPts = null
    } else {
      btn.classList.add('selected')
      bonusPts = parseInt(btn.dataset.pts)
    }
    updateBonusState()
  })

  $('bonusConfirmOk')?.addEventListener('click', handleBonusAward)
  $('bonusConfirmCancel')?.addEventListener('click', () => {
    bonusPts    = null
    bonusReason = null
    $('bonusBtns').querySelectorAll('.bonus-btn').forEach(b => b.classList.remove('selected'))
    $('bonusReasonBtns').querySelectorAll('.bonus-reason-btn').forEach(b => b.classList.remove('selected'))
    updateBonusState()
  })

  $('adjustToggle')?.addEventListener('click', () => {
    const body    = $('adjustBody')
    const chevron = $('adjustChevron')
    const open    = body.style.display !== 'none'
    body.style.display = open ? 'none' : ''
    if (chevron) chevron.textContent = open ? '▾' : '▴'
    if (!open) requestAnimationFrame(() =>
      $('adjustSection').scrollIntoView({ behavior: 'smooth', block: 'start' })
    )
  })

  $('adjustDirBtns')?.addEventListener('click', e => {
    const btn = e.target.closest('.adjust-dir-btn')
    if (!btn) return
    adjustDirection = parseInt(btn.dataset.dir)
    $('adjustDirBtns').querySelectorAll('.adjust-dir-btn').forEach(b => b.classList.toggle('selected', b === btn))
    updateAdjustDisplay()
  })

  $('adjustPad')?.addEventListener('click', e => {
    const btn = e.target.closest('.pad-btn')
    if (!btn) return
    const key = btn.dataset.key
    if (key === 'clear') {
      adjustAmount = ''
    } else if (key === 'back') {
      adjustAmount = adjustAmount.slice(0, -1)
    } else if (adjustAmount === '' && key === '0') {
      // no leading zero
    } else if (adjustAmount.length < 4) {
      adjustAmount += key
    }
    updateAdjustDisplay()
  })

  $('adjustBtn')?.addEventListener('click', handleAdjust)

  $('historyClose')?.addEventListener('click', closeHistory)
  $('historyOverlay')?.addEventListener('click', e => { if (e.target === $('historyOverlay')) closeHistory() })
  document.addEventListener('keydown', e => {
    if (e.key === 'Escape' && $('historyOverlay')?.classList.contains('open')) closeHistory()
  })

  $('redeemBtns')?.addEventListener('click', e => {
    const btn = e.target.closest('.redeem-btn')
    if (!btn || btn.disabled || !selectedMember) return
    handleRedeem(btn)
  })
}

function renderRuleButtons() {
  const rules            = state.rewardRules || []
  const quickRules       = rules.filter(r => r.kind === 'award')
  const redeemRules      = rules.filter(r => r.kind === 'redeem')
  const bonusReasonRules = rules.filter(r => r.kind === 'bonus_reason')
  const bonusAmountRules = rules.filter(r => r.kind === 'bonus_amount')
  const balance          = selectedMember?.balance ?? 0

  if ($('quickSection'))   $('quickSection').style.display   = quickRules.length  ? '' : 'none'
  if ($('sectionDivider')) $('sectionDivider').style.display = quickRules.length  ? '' : 'none'
  if ($('redeemSection'))  $('redeemSection').style.display  = redeemRules.length ? '' : 'none'
  if ($('redeemDivider'))  $('redeemDivider').style.display  = redeemRules.length ? '' : 'none'

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

  const cap          = state.bonusCap
  const validAmounts = cap != null ? bonusAmountRules.filter(r => r.points <= cap) : bonusAmountRules

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

  $('redeemBtns').innerHTML = redeemRules.map(r => {
    const canAfford = r.points <= balance
    return `
      <button class="redeem-btn${canAfford ? '' : ' insufficient'}"
        data-pts="${r.points}" data-label="${escapeHtml(r.label)}" data-rule-id="${escapeHtml(r.id)}"
        ${canAfford ? '' : `title="Requires ${r.points} pts — member has ${balance} pts"`}
        aria-disabled="${!canAfford}">
        <span class="redeem-btn-label">${escapeHtml(r.label)}</span>
        <span class="redeem-btn-cost">−${r.points} pts</span>
      </button>
    `
  }).join('')

  updateBonusState()
}

function openPanel(member) {
  selectedMember  = member
  bonusPts        = null
  bonusReason     = null
  adjustAmount    = ''
  adjustDirection = null

  $('panelId').textContent      = member.public_id
  $('panelBalance').textContent = member.balance
  $('adjustReason').value       = ''
  $('status').textContent       = ''
  $('adjustBtn').disabled       = false
  $('adjustBtn').textContent    = 'Apply adjustment'
  $('adjustBtn').className      = 'award-btn'
  $('adjustBody').style.display = 'none'
  const chevron = $('adjustChevron')
  if (chevron) chevron.textContent = '▾'
  $('adjustDirBtns').querySelectorAll('.adjust-dir-btn').forEach(b => b.classList.remove('selected'))
  updateAdjustDisplay()

  renderRuleButtons()
  $('overlay').classList.add('open')
}

function closePanel() {
  $('overlay').classList.remove('open')
  selectedMember  = null
  bonusPts        = null
  bonusReason     = null
  adjustAmount    = ''
  adjustDirection = null
}

async function handleQuickAward(btn) {
  if (!selectedMember || !state.selectedStoreId) return
  const pts   = parseInt(btn.dataset.pts)
  const label = btn.dataset.label

  btn.disabled = true
  const ok = await showConfirm(`Award ${label}`, `+${pts} pts for ${selectedMember.public_id}`)
  if (!ok) { btn.disabled = false; return }

  const { error } = await awardPoints(selectedMember.user_id, state.selectedStoreId, pts, label, btn.dataset.ruleId)
  if (error) {
    captureError(error, { fn: 'awardPoints' })
    btn.disabled = false
    setStatus(error.message || 'Could not award points.')
    return
  }
  selectedMember.balance += pts
  $('panelBalance').textContent = selectedMember.balance
  btn.classList.add('done')
  btn.querySelector('.btn-label').textContent = 'awarded'
  btn.querySelector('.btn-pts').textContent   = `+${pts} pts`
  setStatus(`Points awarded — +${pts} pts`)
  scheduleReRender()
}

async function handleBonusAward() {
  if (!selectedMember || !bonusPts || !bonusReason || !state.selectedStoreId) return

  $('bonusConfirmOk').disabled     = true
  $('bonusConfirmCancel').disabled = true

  const { error } = await awardPoints(selectedMember.user_id, state.selectedStoreId, bonusPts, bonusReason)
  if (error) {
    captureError(error, { fn: 'awardBonus' })
    $('bonusConfirmOk').disabled     = false
    $('bonusConfirmCancel').disabled = false
    setStatus(error.message || 'Could not award bonus.')
    return
  }
  selectedMember.balance += bonusPts
  $('panelBalance').textContent = selectedMember.balance
  bonusPts    = null
  bonusReason = null
  $('bonusConfirmOk').disabled     = false
  $('bonusConfirmCancel').disabled = false
  $('bonusBtns').querySelectorAll('.bonus-btn').forEach(b => b.classList.remove('selected'))
  $('bonusReasonBtns').querySelectorAll('.bonus-reason-btn').forEach(b => b.classList.remove('selected'))
  updateBonusState()
  setStatus(`Bonus awarded — +${bonusPts} pts`)
  scheduleReRender()
}

async function handleAdjust() {
  if (!selectedMember || !state.selectedStoreId) return
  const amount = parseInt(adjustAmount || '0')

  if (!adjustDirection) { setStatus('Choose Add or Deduct first.'); return }
  if (amount === 0)     { setStatus('Enter an amount.'); return }

  const pts    = adjustDirection * amount
  const reason = ($('adjustReason').value || '').trim() || 'Adjustment'
  const btn    = $('adjustBtn')
  const sign   = pts > 0 ? `+${pts}` : `${pts}`

  btn.disabled = true
  const ok = await showConfirm(`Adjust ${sign} pts`, `${reason} · ${selectedMember.public_id}`)
  if (!ok) { btn.disabled = false; return }

  const { error } = await adjustPoints(selectedMember.user_id, state.selectedStoreId, pts, reason)
  if (error) {
    captureError(error, { fn: 'adjustPoints' })
    btn.disabled = false
    setStatus(error.message || 'Could not apply adjustment.')
    return
  }
  selectedMember.balance += pts
  $('panelBalance').textContent = selectedMember.balance
  btn.textContent               = pts > 0 ? `+${pts} pts applied` : `${pts} pts applied`
  btn.className                 = 'award-btn success'
  adjustAmount    = ''
  adjustDirection = null
  $('adjustDirBtns').querySelectorAll('.adjust-dir-btn').forEach(b => b.classList.remove('selected'))
  updateAdjustDisplay()
  $('adjustReason').value = ''
  scheduleReRender()
  setTimeout(() => {
    btn.textContent = 'Apply adjustment'
    btn.className   = 'award-btn'
    btn.disabled    = false
  }, 1500)
}

async function handleRedeem(btn) {
  if (!selectedMember || !state.selectedStoreId) return
  const pts   = parseInt(btn.dataset.pts)
  const label = btn.dataset.label

  if (selectedMember.balance < pts) {
    await showAlert('Not enough points to redeem')
    return
  }

  btn.disabled = true
  const ok = await showConfirm(`Redeem ${label}`, `−${pts} pts for ${selectedMember.public_id}`)
  if (!ok) { btn.disabled = false; return }

  const { error } = await awardPoints(selectedMember.user_id, state.selectedStoreId, -pts, label, btn.dataset.ruleId)
  if (error) {
    captureError(error, { fn: 'redeemPoints' })
    btn.disabled = false
    setStatus(error.message || 'Could not redeem.')
    return
  }
  selectedMember.balance -= pts
  $('panelBalance').textContent = selectedMember.balance
  btn.classList.add('done')
  btn.querySelector('.redeem-btn-label').textContent = 'Redeemed'
  btn.querySelector('.redeem-btn-cost').textContent  = `−${pts} pts`
  scheduleReRender()
}

function closeHistory() {
  $('historyOverlay').classList.remove('open')
  _historyTrigger?.focus()
  _historyTrigger = null
}

async function handleViewHistory(member, triggerBtn) {
  if (!state.selectedStoreId) return

  _historyTrigger = triggerBtn

  $('historyTitle').textContent    = member.public_id
  $('historySubtitle').textContent = `${member.balance} pts balance`
  $('historyBody').innerHTML       = '<p class="empty">Loading...</p>'
  $('historyOverlay').classList.add('open')
  $('historyClose').focus()

  triggerBtn.disabled = true
  const { data, error } = await loadMemberRecentTransactions(member.user_id, state.selectedStoreId)
  triggerBtn.disabled = false

  if (error) {
    $('historyBody').innerHTML = `
      <p class="empty" style="margin-bottom:12px">Could not load history.</p>
      <div style="text-align:center">
        <button class="award-btn" id="historyRetryBtn" style="width:auto;padding:8px 20px;font-size:13px">Retry</button>
      </div>
    `
    $('historyRetryBtn')?.addEventListener('click', () => handleViewHistory(member, triggerBtn))
    return
  }

  if (!data || !data.length) {
    $('historyBody').innerHTML = '<p class="empty">No transactions yet.</p>'
    return
  }

  $('historyBody').innerHTML = data.map(tx => {
    const pts     = tx.points
    const sign    = pts > 0 ? '+' : ''
    const cls     = pts > 0 ? 'positive' : 'negative'
    const dateStr = formatShortDate(tx.created_at)
    return `
      <div class="history-entry">
        <span class="history-entry-reason">${escapeHtml(tx.reason || '—')}</span>
        <div class="history-entry-right">
          <span class="history-entry-pts ${cls}">${sign}${pts} pts</span>
          <span class="history-entry-date">${dateStr}</span>
        </div>
      </div>
    `
  }).join('')
}

function updateBonusState() {
  const ready     = bonusReason !== null && bonusPts !== null
  const confirmEl = $('bonusConfirm')
  if (!confirmEl) return
  if (ready) {
    $('bonusConfirmMsg').textContent = `Award ${bonusReason} : +${bonusPts} pts`
    confirmEl.style.display = ''
  } else {
    confirmEl.style.display = 'none'
  }
}

function updateAdjustDisplay() {
  const display = $('adjustDisplay')
  if (!display) return
  const num = adjustAmount || '0'
  if (adjustDirection === 1)       display.textContent = `+${num}`
  else if (adjustDirection === -1) display.textContent = `−${num}`
  else                             display.textContent = num
}

function setStatus(msg) {
  clearTimeout(_statusTimer)
  $('status').textContent = msg
  _statusTimer = setTimeout(() => { $('status').textContent = '' }, 3000)
}
