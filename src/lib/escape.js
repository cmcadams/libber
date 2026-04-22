const MAP = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }

export const escapeHtml = value => String(value ?? '').replace(/[&<>"']/g, c => MAP[c])
