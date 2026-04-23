import { state } from '../state/state.js'
import { escapeHtml } from '../lib/escape.js'
import { loadPointsHistory } from '../services/members.js'
import { loadRewardRules } from '../services/admin.js'

export function renderUser(publicId, uuid) {
  const el = document.getElementById('user-id')
  if (!el) return
  el.textContent = publicId || `USR-${String(uuid || '').slice(0, 6).toUpperCase()}` || 'No ID'
}

function formatDate(iso) {
  const d = new Date(iso)
  const diff = Math.floor((Date.now() - d) / 1000)
  if (diff < 60) return 'just now'
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`
  return d.toLocaleDateString()
}

export function renderUserStores() {
  const el = document.getElementById('user-stores')
  if (!el) return

  const stores = state.userStores || []

  if (!stores.length) {
    el.innerHTML = '<p class="empty">No stores joined yet</p>'
    return
  }

  el.innerHTML = `
    <h2 class="section-title">Your stores</h2>
    <div class="store-list">
      ${stores.map(store => `
        <div class="store-card" data-store-id="${escapeHtml(store.store_id)}">
          <div class="store-card-main">
            <span class="store-name">${escapeHtml(store.store_name)}</span>
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
  })
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
  historyEl.innerHTML = '<p class="history-empty">Loading...</p>'

  const storeId = card.dataset.storeId
  const [{ data: rules }, { data: history }] = await Promise.all([
    loadRewardRules(storeId),
    loadPointsHistory(state.user?.id, storeId)
  ])

  const awardRules = (rules || []).filter(r => r.kind === 'award')
  const redeemRules = (rules || []).filter(r => r.kind === 'redeem')

  const historyHtml = (history || []).length ? history.map(row => `
    <div class="history-row">
      <span class="history-reason">${escapeHtml(row.reason || '—')}</span>
      <span class="history-pts${row.points < 0 ? ' history-pts-redeem' : ''}">${row.points > 0 ? '+' : ''}${row.points} pts</span>
      <span class="history-date">${formatDate(row.created_at)}</span>
    </div>
  `).join('') : '<p class="history-empty">No transactions yet</p>'

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

  historyEl.innerHTML = historyHtml + rulesHtml
}
