import { state } from '../state/state.js'
import { escapeHtml } from '../lib/escape.js'
import { getLogoUrl } from '../lib/logoUrl.js'
import { loadStoreHistory } from '../services/members.js'
import { loadRewardRules } from '../services/admin.js'
import { toHumanId, formatRelativeDate } from '../lib/format.js'
import { $ } from '../lib/dom.js'

function nameToColor(name) {
  let h = 0
  for (let i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) | 0
  return 160 + (Math.abs(h) % 180)
}

function initialsAvatar(store) {
  const initials = escapeHtml((store.store_name || '?').slice(0, 2).toUpperCase())
  const hue      = nameToColor(store.store_name || '')
  return `<span class="store-avatar store-avatar--initials" style="--hue:${hue}" aria-hidden="true">${initials}</span>`
}

export function storeAvatar(store) {
  const url = getLogoUrl(store.logo_path, store.logo_updated_at)
  if (url) {
    return `<img class="store-avatar" src="${escapeHtml(url)}" width="36" height="36" alt="" aria-hidden="true" loading="lazy" onerror="this.style.display='none'">`
  }
  return initialsAvatar(store)
}

export function renderUser(publicId, uuid) {
  const el = $('user-id')
  if (!el) return
  el.textContent = toHumanId(publicId, uuid)
}


export function renderUserStores() {
  const el     = $('user-stores')
  const header = $('user-stores-header')
  if (!el) return

  const stores = state.userStores || []

  if (!stores.length) {
    if (header) header.style.display = 'none'
    el.innerHTML = ''
    return
  }

  if (header) header.style.display = ''

  const theme      = document.documentElement.dataset.theme
  const showAvatar = theme === 'mid' || theme === 'max'

  const openIds = new Set(
    [...el.querySelectorAll('.store-card.open')].map(c => c.dataset.storeId)
  )

  el.innerHTML = `
    <div class="store-list">
      ${stores.map(store => `
        <div class="store-card" data-store-id="${escapeHtml(store.store_id)}">
          <div class="store-card-main">
            <div class="store-card-left">
              ${showAvatar ? storeAvatar(store) : ''}
              <span class="store-name">${escapeHtml(store.store_name)}</span>
            </div>
            <div class="store-card-right">
              <span class="store-points">${store.balance} pts</span>
              <span class="chevron">›</span>
            </div>
          </div>
          <div class="store-history" style="display:none"></div>
        </div>
      `).join('')}
    </div>
  `

  el.querySelectorAll('.store-card').forEach(card => {
    card.addEventListener('click', () => toggleHistory(card))
    if (openIds.has(card.dataset.storeId)) toggleHistory(card)
  })
}

function txnKind(row, awardLabels, bonusLabels) {
  if (row.points < 0)                   return 'redeem'
  if (awardLabels.has(row.reason))      return 'award'
  if (bonusLabels.has(row.reason))      return 'bonus'
  return 'adjust'
}

function renderStoreDetail(el, history, rules) {
  const awardRules  = (rules || []).filter(r => r.kind === 'award')
  const redeemRules = (rules || []).filter(r => r.kind === 'redeem')
  const awardLabels = new Set(awardRules.map(r => r.label))
  const bonusLabels = new Set((rules || []).filter(r => r.kind === 'bonus_reason').map(r => r.label))

  const historyHtml = (history || []).length
    ? history.map(row => {
        const kind = txnKind(row, awardLabels, bonusLabels)
        return `
        <div class="history-row">
          <span class="history-reason">${escapeHtml(row.reason || '—')}</span>
          <span class="history-pts history-pts-${kind}">${row.points > 0 ? '+' : ''}${row.points} pts</span>
          <span class="history-date">${formatRelativeDate(row.created_at)}</span>
        </div>`
      }).join('')
    : '<p class="history-empty">No transactions yet</p>'

  const rulesHtml = (awardRules.length || redeemRules.length) ? `
    <div class="rules-divider"></div>
    ${awardRules.length ? `
      <p class="rules-title">How to earn</p>
      ${awardRules.map(r => `
        <div class="rule-row">
          <span class="rule-label">${escapeHtml(r.label)}</span>
          <span class="rule-pts">+${r.points} pts</span>
        </div>
      `).join('')}
    ` : ''}
    ${redeemRules.length ? `
      <p class="rules-title">Rewards</p>
      ${redeemRules.map(r => `
        <div class="rule-row">
          <span class="rule-label">${escapeHtml(r.label || 'Reward')}</span>
          <span class="rule-pts">−${r.points} pts</span>
        </div>
      `).join('')}
    ` : ''}
  ` : ''

  el.innerHTML = historyHtml + rulesHtml
}

async function toggleHistory(card) {
  const historyEl = card.querySelector('.store-history')
  if (!historyEl) return

  if (historyEl.style.display !== 'none') {
    historyEl.style.display = 'none'
    card.classList.remove('open')
    return
  }

  historyEl.style.display = 'block'
  card.classList.add('open')

  const storeId = card.dataset.storeId
  const cached  = state.storeData?.[storeId]

  // Render from cache immediately — no loading flicker on return visits
  if (cached) {
    renderStoreDetail(historyEl, cached.history, cached.rules)
  } else {
    historyEl.innerHTML = '<p class="history-empty">Loading...</p>'
  }

  // Always refresh in background
  const [{ data: rules, error: rulesErr }, { data: history, error: histErr }] = await Promise.all([
    loadRewardRules(storeId),
    loadStoreHistory(storeId)
  ])

  if (rulesErr || histErr) {
    if (!cached) historyEl.innerHTML = '<p class="history-empty">Could not load.</p>'
    return
  }

  if (state.storeData) {
    state.storeData[storeId] = { rules: rules || [], history: history || [] }
  }

  renderStoreDetail(historyEl, history, rules)
}
