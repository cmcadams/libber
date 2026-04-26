export const toHumanId = (publicId, userId) =>
  publicId || `USR-${String(userId || '').slice(0, 6).toUpperCase()}`
