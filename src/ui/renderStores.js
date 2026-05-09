import { joinStore, unjoinStore } from '../services/stores.js'
import { state } from '../state/state.js'
import { renderUserStores, storeAvatar } from './renderUser.js'
import { $ } from '../lib/dom.js'
import { captureError } from '../lib/sentry.js'

const prevBalances = new Map()

export function renderStores(stores) {
  const container = $('stores-list')
  const section   = $('stores-section')
  if (!container) return

  const storeList = stores || []

  if (!storeList.length) {
    if (section) section.style.display = 'none'
    return
  }

  if (section) section.style.display = ''

  const joinedIds  = new Set((state.userStores || []).map(s => s.store_id))
  const theme      = document.documentElement.dataset.theme
  const showAvatar = theme === 'mid' || theme === 'max'

  container.innerHTML = ''
  const list = document.createElement('div')
  list.className = 'available-stores'

  for (const store of storeList) {
    const joined = joinedIds.has(store.id)

    const card    = document.createElement('div')
    card.className = 'store-join-card'

    const left = document.createElement('div')
    left.className = 'store-card-left'
    if (showAvatar) {
      left.insertAdjacentHTML('beforeend', storeAvatar({
        store_name:      store.name ?? 'Unknown Store',
        logo_path:       store.logo_path ?? null,
        logo_updated_at: null,
      }))
    }

    const nameEl      = document.createElement('span')
    nameEl.className  = 'store-join-name'
    nameEl.textContent = store.name ?? 'Unknown Store'

    left.appendChild(nameEl)

    const btn         = document.createElement('button')
    btn.className     = joined ? 'unjoin-btn' : 'join-btn'
    btn.textContent   = joined ? 'Unjoin' : 'Join'

    btn.addEventListener('click', () => {
      if (btn.classList.contains('unjoin-btn')) handleUnjoin(store, btn)
      else handleJoin(store, btn)
    })

    card.appendChild(left)
    card.appendChild(btn)
    list.appendChild(card)
  }

  container.appendChild(list)
}

async function handleJoin(store, btn) {
  if (!state.user) return

  btn.disabled    = true
  btn.textContent = '...'

  const { error } = await joinStore(store.id)

  if (error) {
    captureError(error, { fn: 'joinStore' })
    btn.textContent = 'Failed'
    setTimeout(() => { btn.disabled = false; btn.textContent = 'Join' }, 2000)
    return
  }

  state.userStores = [...(state.userStores || []), {
    store_id:        store.id,
    store_name:      store.name ?? 'Unknown Store',
    balance:         prevBalances.get(store.id) ?? 0,
    logo_path:       store.logo_path ?? null,
    logo_updated_at: null,
  }]
  prevBalances.delete(store.id)

  try { localStorage.removeItem(`libber_home_${state.user.id}`) } catch {}
  renderUserStores()

  btn.textContent = 'Unjoin'
  btn.className   = 'unjoin-btn'
  btn.disabled    = false
}

async function handleUnjoin(store, btn) {
  if (!confirm(`Leave ${store.name ?? 'this store'}? Your points are saved if you rejoin.`)) return

  btn.disabled    = true
  btn.textContent = '...'

  const { error } = await unjoinStore(store.id)

  if (error) {
    captureError(error, { fn: 'unjoinStore' })
    btn.textContent = 'Failed'
    setTimeout(() => { btn.disabled = false; btn.textContent = 'Unjoin' }, 2000)
    return
  }

  const existing = (state.userStores || []).find(s => s.store_id === store.id)
  if (existing) prevBalances.set(store.id, existing.balance)

  state.userStores = (state.userStores || []).filter(s => s.store_id !== store.id)
  if (state.storeData) delete state.storeData[store.id]

  try { localStorage.removeItem(`libber_home_${state.user.id}`) } catch {}
  renderUserStores()

  btn.textContent = 'Join'
  btn.className   = 'join-btn'
  btn.disabled    = false
}
