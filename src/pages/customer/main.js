import QRCode from 'qrcode'
import { captureError } from '../../lib/sentry.js'
import { escapeHtml } from '../../lib/escape.js'
import { initAuth, resetSession } from '../../services/auth.js'
import { loadCustomerHome, subscribeToPointsInserts } from '../../services/members.js'
import { renderUser, renderUserStores } from '../../ui/renderUser.js'
import { renderStores } from '../../ui/renderStores.js'
import * as savePrompt   from '../../ui/savePrompt.js'
import { state } from '../../state/state.js'
import { $ } from '../../lib/dom.js'
import { applyTheme } from '../../lib/theme.js'

// ── Balance helpers ───────────────────────────────────────────────────────────

function getTotalBalance(data) {
  return (data?.memberships || []).reduce((sum, m) => sum + (m.balance || 0), 0)
}

// Returns true only when there was a previous cache to compare against and
// fresh data shows a higher total balance — i.e. new points were actually awarded.
function hasNewPoints(prevBal, freshData, hadCache) {
  return hadCache && getTotalBalance(freshData) > prevBal
}

// ── Cache helpers ─────────────────────────────────────────────────────────────

const homeKey    = id => `libber_home_${id}`
const STORES_KEY = 'libber_stores'
const STORES_TTL = 24 * 60 * 60 * 1000

function readJson(key)        { try { return JSON.parse(localStorage.getItem(key)) } catch { return null } }
function writeJson(key, val)  { try { localStorage.setItem(key, JSON.stringify(val)) } catch {} }

function readHomeCache(userId)        { return readJson(homeKey(userId)) }
function writeHomeCache(userId, data) { writeJson(homeKey(userId), data) }

function readStoresCache() {
  const entry = readJson(STORES_KEY)
  if (!entry) return null
  return (Date.now() - entry.ts < STORES_TTL) ? entry.stores : null
}
function writeStoresCache(stores) { writeJson(STORES_KEY, { stores, ts: Date.now() }) }

// ── Apply data to state + DOM ─────────────────────────────────────────────────

function applyHomeData(data, uuid) {
  savePrompt.render(data)
  renderUser(data.public_id, uuid)

  state.userStores = (data.memberships || []).map(m => ({
    store_id:        m.store_id,
    store_name:      m.store_name,
    balance:         m.balance,
    logo_path:       m.logo_path       ?? null,
    logo_updated_at: m.logo_updated_at ?? null,
  }))

  state.storeData = state.storeData || {}
  for (const m of (data.memberships || [])) {
    state.storeData[m.store_id] = { rules: m.rules || [], history: m.history || [] }
  }

  renderUserStores()
  if (data.stores != null) renderStores(data.stores)
}

// ── Show Staff overlay ────────────────────────────────────────────────────────

function initShowStaff() {
  const trigger   = $('header-id')
  const overlay   = $('staff-overlay')
  const overlayId = $('staff-overlay-id')
  const doneBtn   = $('staff-overlay-done')
  if (!trigger || !overlay) return

  function exitStaffView() {
    overlay.classList.remove('active')
    if (document.fullscreenElement) document.exitFullscreen().catch(() => {})
    screen.orientation?.unlock()
  }

  trigger.addEventListener('click', () => {
    const idText = $('user-id').textContent
    overlayId.innerHTML = idText.split(' ').map(p => `<span>${escapeHtml(p)}</span>`).join('')
    QRCode.toCanvas($('staff-overlay-qr'), idText, {
      width: 220,
      margin: 2,
      color: { dark: '#000000', light: '#ffffff' },
    }).catch(() => {})
    overlay.classList.add('active')
    document.documentElement.requestFullscreen?.().catch(() => {})
    screen.orientation?.lock('portrait').catch(() => {})
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

// ── Dev section (testing only) ────────────────────────────────────────────────

function initDevSection() {
  const tap     = $('dev-tap')
  const section = $('dev-section')
  const resetBtn = $('dev-reset')
  if (!tap || !section || !resetBtn) return

  let count = 0
  let timer = null

  tap.addEventListener('click', () => {
    count++
    clearTimeout(timer)
    timer = setTimeout(() => { count = 0 }, 1500)
    if (count >= 7) {
      count = 0
      clearTimeout(timer)
      section.classList.add('visible')
    }
  })

  resetBtn.addEventListener('click', async () => {
    if (!confirm('Clear all local data and start as a new user?')) return
    await resetSession()
  })
}

// ── Boot ──────────────────────────────────────────────────────────────────────

async function init() {
  try {
    const user = await initAuth()
    if (!user) return

    // 1. Render from cache immediately — instant on return visits.
    //    Capture balance before render so we can detect new points after
    //    fresh data arrives.
    const cached       = readHomeCache(user.id)
    const hadCache     = cached !== null
    const prevBal      = getTotalBalance(cached)
    const cachedStores = readStoresCache()

    if (cached) {
      if (cached.stores == null && cachedStores) cached.stores = cachedStores
      applyHomeData(cached, user.id)
    }

    // Wire up Show Staff before the network round-trip.
    initShowStaff()

    // 2. Fetch fresh data. Skip the stores query when the cache is still valid.
    const { data } = await loadCustomerHome(!cachedStores)
    if (data) {
      if (cachedStores) {
        data.stores = cachedStores
      } else {
        writeStoresCache(data.stores)
      }
      writeHomeCache(user.id, data)
      applyHomeData(data, user.id)
      if (hasNewPoints(prevBal, data, hadCache)) savePrompt.glow()
    }

    // 3. Real-time: re-fetch when a points row is inserted.
    subscribeToPointsInserts(user.id, async () => {
      const stores = readStoresCache()
      const { data: fresh } = await loadCustomerHome(!stores)
      if (!fresh) return

      if (stores) fresh.stores = stores
      else writeStoresCache(fresh.stores)

      // Read previous balance from cache before overwriting it.
      const prevRtBal = getTotalBalance(readHomeCache(user.id))
      writeHomeCache(user.id, fresh)
      applyHomeData(fresh, user.id)
      if (hasNewPoints(prevRtBal, fresh, true)) savePrompt.glow()
    })

    // 4. Refresh button.
    const refreshBtn = $('refresh-btn')
    if (refreshBtn) {
      refreshBtn.addEventListener('click', async () => {
        refreshBtn.classList.add('loading')
        refreshBtn.disabled = true
        try {
          const prevRefBal = getTotalBalance(readHomeCache(user.id))
          const { data: fresh } = await loadCustomerHome(true)
          if (fresh) {
            writeStoresCache(fresh.stores)
            writeHomeCache(user.id, fresh)
            applyHomeData(fresh, user.id)
            if (hasNewPoints(prevRefBal, fresh, true)) savePrompt.glow()
          }
        } catch (err) {
          captureError(err, { fn: 'refresh' })
        } finally {
          refreshBtn.classList.remove('loading')
          refreshBtn.disabled = false
        }
      })
    }

  } catch (err) {
    captureError(err)
    alert('Something went wrong')
  }
}

// 5. Register service worker for PWA installability.
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('/apps/customer/sw.js').catch(() => {})
}

applyTheme()
initDevSection()
init()
