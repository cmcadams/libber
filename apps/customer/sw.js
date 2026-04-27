// Minimal service worker — enables PWA installability.
// The app uses localStorage for data caching; the SW handles the shell.

const CACHE = 'libber-customer-v__SW_CACHE_VERSION__'
const SHELL = ['/apps/customer/', '/apps/customer/index.html']

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)))
  self.skipWaiting()
})

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))
    ).then(() => self.clients.claim())
  )
})

self.addEventListener('fetch', e => {
  // Network first; fall back to cached shell for navigation
  if (e.request.mode === 'navigate') {
    e.respondWith(fetch(e.request).catch(() => caches.match('/apps/customer/')))
  }
})
