import { initAuth } from '../../services/auth.js'
import { getStores } from '../../services/stores.js'
import { loadUserStoresWithPoints, loadUserProfile } from '../../services/members.js'
import { renderUser, renderUserStores } from '../../ui/renderUser.js'
import { renderStores } from '../../ui/renderStores.js'

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
    // 1. Auth
    const user = await initAuth()
    if (!user) return

    // 2. Load user's profile (public_id from Supabase)
    const profile = await loadUserProfile(user.id)
    const publicId = profile?.public_id || null

    renderUser(publicId, user.id)
    initShowStaff()

    // 3. Load user's stores with points
    await loadUserStoresWithPoints(user.id)
    renderUserStores()

    // 4. Setup refresh button
    const refreshBtn = document.getElementById('refresh-btn')
    if (refreshBtn) {
      refreshBtn.addEventListener('click', async () => {
        refreshBtn.classList.add('loading')
        refreshBtn.disabled = true
        await loadUserStoresWithPoints(user.id)
        renderUserStores()
        refreshBtn.classList.remove('loading')
        refreshBtn.disabled = false
      })
    }

    // 5. Load available stores to join
    const { data: stores, error } = await getStores()

    if (error) throw error

    // 6. Render
    renderStores(stores)

  } catch (err) {
    console.error(err)
    alert('Something went wrong')
  }
}

init()
