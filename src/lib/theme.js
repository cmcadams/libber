const VALID   = new Set(['min', 'mid', 'max'])
const KEY     = 'libber_theme'
const DEFAULT = 'mid'

export function getTheme() {
  try {
    const v = localStorage.getItem(KEY)
    return VALID.has(v) ? v : DEFAULT
  } catch { return DEFAULT }
}

export function setTheme(val) {
  if (!VALID.has(val)) return
  try { localStorage.setItem(KEY, val) } catch {}
  document.documentElement.dataset.theme = val
}

export function applyTheme() {
  document.documentElement.dataset.theme = getTheme()
}
