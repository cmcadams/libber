import { state } from '../state/state.js'

export function renderUser(publicId, uuid) {
  const el = document.getElementById('user-id')
  if (!el) return

  const displayText = publicId && uuid 
    ? `${publicId} ${uuid}` 
    : publicId || uuid || 'No ID'
  
  el.textContent = displayText
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
    <div class="store-list">
      ${stores.map(store => `
        <div class="store-card">
          <span class="store-name">${store.store_name}</span>
          <span class="store-points">${store.balance} pts</span>
        </div>
      `).join('')}
    </div>
  `
}
