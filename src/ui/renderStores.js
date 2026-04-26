import { joinStore } from '../services/stores.js'
import { state } from '../state/state.js'
import { renderUserStores } from './renderUser.js'
import { $ } from '../lib/dom.js'

export function renderStores(stores) {
  const container = $('stores-list')
  const section = $('stores-section')

  if (!container) return

  container.innerHTML = ''

  const joinedStoreIds = new Set((state.userStores || []).map(s => s.store_id))
  const unjoinedStores = (stores || []).filter(s => !joinedStoreIds.has(s.id))

  if (!unjoinedStores.length) {
    if (section) section.style.display = 'none'
    return
  }

  if (section) section.style.display = ''

  const listDiv = document.createElement('div')
  listDiv.className = 'available-stores'

  unjoinedStores.forEach(store => {
    const card = document.createElement('div')
    card.className = 'store-join-card'

    const nameSpan = document.createElement('span')
    nameSpan.className = 'store-join-name'
    nameSpan.textContent = store.name ?? 'Unknown Store'

    const button = document.createElement('button')
    button.className = 'join-btn'
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

      state.userStores = [...(state.userStores || []), {
        store_id:   store.id,
        store_name: store.name ?? 'Unknown Store',
        balance:    0
      }]
      try { localStorage.removeItem(`libber_home_${state.user?.id}`) } catch {}
      renderUserStores()

      card.remove()
      if (!listDiv.children.length && section) section.style.display = 'none'
    })

    card.appendChild(nameSpan)
    card.appendChild(button)
    listDiv.appendChild(card)
  })

  container.appendChild(listDiv)
}
