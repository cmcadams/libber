import { initAuth } from './services/auth.js'
import { getStores } from './services/stores.js'
import { loadUserStoresWithPoints, loadUserProfile } from './services/members.js'
import { renderUser, renderUserStores } from './ui/renderUser.js'
import { renderStores } from './ui/renderStores.js'

async function init() {
  try {
    // 1. Auth
    const user = await initAuth()
    if (!user) return

    // 2. Load user's profile (public_id from Supabase)
    const profile = await loadUserProfile(user.id)
    const publicId = profile?.public_id || null

    renderUser(publicId, user.id)

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
