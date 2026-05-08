import { supabase } from './supabase.js'

export function getLogoUrl(logoPath, logoUpdatedAt) {
  if (!logoPath) return null
  const { data } = supabase.storage.from('store-logos').getPublicUrl(logoPath)
  const url = data?.publicUrl
  if (!url) return null
  return logoUpdatedAt ? `${url}?v=${encodeURIComponent(logoUpdatedAt)}` : url
}
