export const toHumanId = (publicId, userId) =>
  publicId || `USR-${String(userId || '').slice(0, 6).toUpperCase()}`

function parseUtc(iso) {
  return new Date(/[Z+]/.test(iso) ? iso : iso + 'Z')
}

export function formatRelativeDate(iso) {
  const diff = Math.floor((Date.now() - parseUtc(iso)) / 1000)
  if (diff < 60)    return 'just now'
  if (diff < 3600)  return `${Math.floor(diff / 60)}m ago`
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`
  return parseUtc(iso).toLocaleDateString()
}

export function formatShortDate(iso) {
  return parseUtc(iso).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
}
