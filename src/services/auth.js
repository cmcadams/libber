import { supabase } from '../lib/supabase.js'
import { state } from '../state/state.js'

export async function initAuth() {
  async function signInAnonOrThrow() {
    const { data, error } = await supabase.auth.signInAnonymously()
    if (error) {
      throw new Error(`Anonymous sign-in failed: ${error.message}`)
    }
  }

  const { data: { session } } = await supabase.auth.getSession()

  if (!session) {
    await signInAnonOrThrow()
  }

  let { data: userData, error: userError } = await supabase.auth.getUser()

  // Common after manual cleanup: stored JWT points to a deleted auth user.
  if (userError?.message?.includes('does not exist')) {
    await supabase.auth.signOut()
    await signInAnonOrThrow()
    const retry = await supabase.auth.getUser()
    userData = retry.data
    userError = retry.error
  }

  if (userError) {
    throw new Error(`Could not load current user: ${userError.message}`)
  }
  if (!userData?.user) {
    throw new Error('Auth succeeded but no user was returned.')
  }
  state.user = userData.user
  return state.user
}

export async function resetSession() {
  localStorage.clear()
  await supabase.auth.signOut().catch(() => {})
  location.reload()
}
