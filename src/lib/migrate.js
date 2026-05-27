/**
 * One-time localStorage key migration: libber_* → gotya_*
 *
 * Scans all keys, migrates any starting with 'libber_' to 'gotya_'.
 * Idempotent — safe to call on every boot.
 * Handles dynamic keys (e.g. libber_home_<userId>) automatically.
 */
export function migrateStorage() {
  try {
    const toMigrate = []
    for (let i = 0; i < localStorage.length; i++) {
      const key = localStorage.key(i)
      if (key && key.startsWith('libber_')) toMigrate.push(key)
    }
    for (const oldKey of toMigrate) {
      const newKey = 'gotya_' + oldKey.slice('libber_'.length)
      if (localStorage.getItem(newKey) === null) {
        localStorage.setItem(newKey, localStorage.getItem(oldKey))
      }
      localStorage.removeItem(oldKey)
    }
  } catch {}
}
