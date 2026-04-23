import { initAuth } from '../../services/auth.js'
import { loadCustomerHome } from '../../services/members.js'
import { renderUser, renderUserStores } from '../../ui/renderUser.js'
import { renderStores } from '../../ui/renderStores.js'
import { state } from '../../state/state.js'

const cacheKey = id => `libber_home_${id}`

function readCache(userId) {
  try {
    const raw = localStorage.getItem(cacheKey(userId))
    return raw ? JSON.parse(raw) : null
  } catch { return null }
}

function writeCache(userId, data) {
  try { localStorage.setItem(cacheKey(userId), JSON.stringify(data)) } catch {}
}

function applyHomeData(data, uuid) {
  renderUser(data.public_id, uuid)
  state.userStores = (data.memberships || []).map(m => ({
    store_id: m.store_id,
    store_name: m.store_name,
    balance: m.balance
  }))
  renderUserStores()
  renderStores(data.stores || [])
}

function initShowStaff() {
  const btn = document.getElementById('show-staff-btn')
  const overlay = document.getElementById('staff-overlay')
  const overlayId = document.getElementById('staff-overlay-id')
  const doneBtn = document.getElementById('staff-overlay-done')

  if (!btn || !overlay) return

  function exitStaffView() {
    overlay.classList.remove('active')
    if (document.fullscreenElement) document.exitFullscreen().catch(() => {})
    screen.orientation?.unlock()
  }

  btn.addEventListener('click', () => {
    overlayId.textContent = document.getElementById('user-id').textContent
    overlay.classList.add('active')
    document.documentElement.requestFullscreen?.().catch(() => {})
    screen.orientation?.lock('landscape').catch(() => {})
  })

  doneBtn.addEventListener('click', exitStaffView)
  overlay.addEventListener('click', e => { if (e.target !== doneBtn) exitStaffView() })

  document.addEventListener('fullscreenchange', () => {
    if (!document.fullscreenElement) {
      overlay.classList.remove('active')
      screen.orientation?.unlock()
    }
  })
}

async function init() {
  try {
    const user = await initAuth()
    if (!user) return

    // Render from cache immediately so the page feels instant on return visits
    const cached = readCache(user.id)
    if (cached) applyHomeData(cached, user.id)

    // Single RPC: profile + memberships + balances + stores in one round trip
    const data = await loadCustomerHome()
    if (data) {
      writeCache(user.id, data)
      applyHomeData(data, user.id)
    }

    initShowStaff()

    const refreshBtn = document.getElementById('refresh-btn')
    if (refreshBtn) {
      refreshBtn.addEventListener('click', async () => {
        refreshBtn.classList.add('loading')
        refreshBtn.disabled = true
        const fresh = await loadCustomerHome()
        if (fresh) {
          writeCache(user.id, fresh)
          applyHomeData(fresh, user.id)
        }
        refreshBtn.classList.remove('loading')
        refreshBtn.disabled = false
      })
    }

  } catch (err) {
    console.error(err)
    alert('Something went wrong')
  }
}

init()
