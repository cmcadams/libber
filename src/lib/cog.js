import { $ } from './dom.js'

let deferredPrompt = null

window.addEventListener('beforeinstallprompt', e => {
  e.preventDefault()
  deferredPrompt = e
  updateCogMenu()
})

window.addEventListener('appinstalled', () => {
  deferredPrompt = null
  const cogBtn  = $('cogBtn')
  const cogMenu = $('cogMenu')
  if (cogBtn)  cogBtn.style.display  = 'none'
  if (cogMenu) cogMenu.style.display = 'none'
})

function updateCogMenu() {
  const menu = $('cogMenu')
  if (!menu) return
  if (deferredPrompt) {
    menu.innerHTML = '<button class="cog-install-btn" id="cogInstallBtn">Add to home screen</button>'
  } else {
    const isIos = /iphone|ipad|ipod/i.test(navigator.userAgent)
    const text  = isIos
      ? 'Tap <strong>Share ↑</strong> then <strong>Add to Home Screen</strong> to install.'
      : 'Open your browser menu and tap <strong>Add to Home Screen</strong> to install.'
    menu.innerHTML = `<p class="cog-instructions">${text}</p>`
  }
}

function wireCog() {
  $('cogBtn')?.addEventListener('click', () => {
    const menu = $('cogMenu')
    if (!menu) return
    menu.style.display = menu.style.display === 'none' ? '' : 'none'
  })

  $('cogMenu')?.addEventListener('click', async e => {
    const btn = e.target.closest('#cogInstallBtn')
    if (!btn || !deferredPrompt) return
    deferredPrompt.prompt()
    const { outcome } = await deferredPrompt.userChoice
    deferredPrompt = null
    if (outcome === 'accepted') {
      $('cogBtn').style.display  = 'none'
      $('cogMenu').style.display = 'none'
    } else {
      updateCogMenu()
    }
  })
}

export function initCog() {
  if (window.matchMedia('(display-mode: standalone)').matches) {
    const cogBtn = $('cogBtn')
    if (cogBtn) cogBtn.style.display = 'none'
    return
  }
  updateCogMenu()
  wireCog()
}
