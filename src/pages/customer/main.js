import { initAuth } from '../../services/auth.js'
import { loadCustomerHome, subscribeToPointsInserts } from '../../services/members.js'
import { renderUser, renderUserStores } from '../../ui/renderUser.js'
import { renderStores } from '../../ui/renderStores.js'
import { state } from '../../state/state.js'

// ── Save prompt ───────────────────────────────────────────────────────────────

function getTotalBalance(data) {
  return (data?.memberships || []).reduce((sum, m) => sum + (m.balance || 0), 0)
}

function renderSavePrompt(data) {
  const el = document.getElementById('save-prompt')
  const btn = document.getElementById('save-prompt-btn')
  if (!el || !btn) return
  if (data.email_saved || !data.save_prompt) return
  btn.textContent = data.save_prompt.text
  el.style.display = ''
}

function glowSavePrompt() {
  const btn = document.getElementById('save-prompt-btn')
  const el = document.getElementById('save-prompt')
  if (!btn || !el || el.style.display === 'none') return
  btn.classList.remove('glowing')
  void btn.offsetWidth
  btn.classList.add('glowing')
  btn.addEventListener('animationend', () => btn.classList.remove('glowing'), { once: true })
}

// ── Cache helpers ─────────────────────────────────────────────────────────────

const homeKey  = id => `libber_home_${id}`
const STORES_KEY = 'libber_stores'
const STORES_TTL = 24 * 60 * 60 * 1000

function readJson(key)       { try { return JSON.parse(localStorage.getItem(key)) } catch { return null } }
function writeJson(key, val) { try { localStorage.setItem(key, JSON.stringify(val)) } catch {} }

function readHomeCache(userId)  { return readJson(homeKey(userId)) }
function writeHomeCache(userId, data) { writeJson(homeKey(userId), data) }

function readStoresCache() {
  const entry = readJson(STORES_KEY)
  if (!entry) return null
  return (Date.now() - entry.ts < STORES_TTL) ? entry.stores : null
}
function writeStoresCache(stores) { writeJson(STORES_KEY, { stores, ts: Date.now() }) }

// ── Apply data to state + DOM ─────────────────────────────────────────────────

function applyHomeData(data, uuid) {
  renderSavePrompt(data)
  renderUser(data.public_id, uuid)

  state.userStores = (data.memberships || []).map(m => ({
    store_id:   m.store_id,
    store_name: m.store_name,
    balance:    m.balance
  }))

  // Cache per-store rules + history for instant card opens
  state.storeData = state.storeData || {}
  for (const m of (data.memberships || [])) {
    state.storeData[m.store_id] = { rules: m.rules || [], history: m.history || [] }
  }

  renderUserStores()
  if (data.stores != null) renderStores(data.stores)
}

// ── Notifications ─────────────────────────────────────────────────────────────

function maybeNotify(row) {
  if (!('Notification' in window) || Notification.permission !== 'granted') return
  if (document.visibilityState === 'visible') return
  const store = (state.userStores || []).find(s => s.store_id === row.store_id)
  const name  = store?.store_name || 'a store'
  const pts   = row.points
  new Notification('Libber', {
    body: pts > 0 ? `+${pts} pts at ${name}` : `${Math.abs(pts)} pts redeemed at ${name}`,
    icon: '/apps/customer/icon.svg'
  })
}

function requestNotificationPermission() {
  if ('Notification' in window && Notification.permission === 'default') {
    Notification.requestPermission()
  }
}

// ── Show Staff overlay ────────────────────────────────────────────────────────

function initShowStaff() {
  const btn      = document.getElementById('show-staff-btn')
  const overlay  = document.getElementById('staff-overlay')
  const overlayId = document.getElementById('staff-overlay-id')
  const doneBtn  = document.getElementById('staff-overlay-done')
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

// ── Boot ──────────────────────────────────────────────────────────────────────

async function init() {
  try {
    const user = await initAuth()
    if (!user) return

    // 1. Render from home cache immediately (instant on return visits)
    const cached = readHomeCache(user.id)
    const cachedBalance = getTotalBalance(cached)
    if (cached) {
      const cachedStores = readStoresCache()
      if (cached.stores == null && cachedStores) cached.stores = cachedStores
      applyHomeData(cached, user.id)
    }

    // Wire up Show Staff now — button is visible from page load, don't wait for network
    initShowStaff()

    // 2. Fetch fresh data — skip stores query if cache is still fresh
    const cachedStores = readStoresCache()
    const data = await loadCustomerHome(!cachedStores)
    if (data) {
      if (cachedStores) {
        data.stores = cachedStores        // inject cached stores so renderStores fires
      } else {
        writeStoresCache(data.stores)     // fresh stores — update cache
      }
      writeHomeCache(user.id, data)
      applyHomeData(data, user.id)
      if (getTotalBalance(data) > cachedBalance) glowSavePrompt()
    }

    // 3. Ask for notification permission after a short delay
    setTimeout(requestNotificationPermission, 4000)

    // 4. Real-time: refresh home data when points change
    subscribeToPointsInserts(user.id, async row => {
      const stores = readStoresCache()
      const fresh  = await loadCustomerHome(!stores)
      if (fresh) {
        if (stores) fresh.stores = stores
        else writeStoresCache(fresh.stores)
        const prevBalance = getTotalBalance(readHomeCache(user.id))
        writeHomeCache(user.id, fresh)
        applyHomeData(fresh, user.id)
        if (getTotalBalance(fresh) > prevBalance) glowSavePrompt()
        maybeNotify(row)
      }
    })

    // 5. Refresh button
    const refreshBtn = document.getElementById('refresh-btn')
    if (refreshBtn) {
      refreshBtn.addEventListener('click', async () => {
        refreshBtn.classList.add('loading')
        refreshBtn.disabled = true
        const prevBalance = getTotalBalance(readHomeCache(user.id))
        const fresh = await loadCustomerHome(true)
        if (fresh) {
          writeStoresCache(fresh.stores)
          writeHomeCache(user.id, fresh)
          applyHomeData(fresh, user.id)
          if (getTotalBalance(fresh) > prevBalance) glowSavePrompt()
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

// 6. Register service worker for PWA installability
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('/apps/customer/sw.js').catch(() => {})
}

init()
