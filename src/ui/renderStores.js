import { joinStore } from '../services/stores.js'
import { state } from '../state/state.js'
import { loadUserStoresWithPoints } from '../services/members.js'
import { renderUserStores } from './renderUser.js'

export function renderStores(stores) {
  const container = document.getElementById('stores-list')

  if (!container) return

  container.innerHTML = ''

  if (!stores || stores.length === 0) {
    container.innerHTML = '<p class="empty">No stores available</p>'
    return
  }

  // Get already-joined store IDs
  const joinedStoreIds = new Set((state.userStores || []).map(s => s.store_id))

  const listDiv = document.createElement('div')
  listDiv.className = 'available-stores'

  stores.forEach(store => {
    const isJoined = joinedStoreIds.has(store.id)
    
    const card = document.createElement('div')
    card.className = 'store-join-card'

    const nameSpan = document.createElement('span')
    nameSpan.className = 'store-join-name'
    nameSpan.textContent = store.name ?? 'Unknown Store'

    const button = document.createElement('button')
    button.className = 'join-btn'
    
    if (isJoined) {
      button.textContent = 'Joined'
      button.disabled = true
    } else {
      button.textContent = 'Join'

      button.addEventListener('click', async () => {
        button.disabled = true
        button.textContent = '...'

        if (!state.user) {
          alert('User not ready')
          button.disabled = false
          button.textContent = 'Join'
          return
        }

        const { error } = await joinStore(store.id)

        if (error) {
          console.error(error)
          alert('Failed to join')
          button.disabled = false
          button.textContent = 'Join'
          return
        }

        button.textContent = 'Joined'
        button.disabled = true

        // Refresh user's stores to show newly joined store
        await loadUserStoresWithPoints(state.user.id)
        renderUserStores()
      })
    }

    card.appendChild(nameSpan)
    card.appendChild(button)
    listDiv.appendChild(card)
  })

  container.appendChild(listDiv)
}
