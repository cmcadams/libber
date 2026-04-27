import { supabase } from '../../lib/supabase.js'
import { $, $$ } from '../../lib/dom.js'

const REDIRECT_URL = `${window.location.origin}/apps/customer/save.html`
const HOME_URL     = '/apps/customer/'

// ── RPC ──────────────────────────────────────────────────────────────────────

async function markEmailSaved() {
  await supabase.rpc('mark_email_saved')
}

// ── View switching ─────────────────────────────────────────────────────────

function showView(id) {
  $$('.view').forEach(el => { el.hidden = el.id !== id })
}

function setError(msg) {
  const el = $('error-msg')
  if (!el) return
  el.textContent = msg
  el.hidden      = !msg
}

// ── OAuth / magic link callback ───────────────────────────────────────────

function handleCallback() {
  showView('view-success')

  const { data: { subscription } } = supabase.auth.onAuthStateChange(async (event) => {
    if (event === 'SIGNED_IN' || event === 'USER_UPDATED') {
      subscription.unsubscribe()
      await markEmailSaved()
      setTimeout(() => { location.href = HOME_URL }, 1500)
    }
  })
}

// ── Provider buttons ──────────────────────────────────────────────────────

function initProviders() {
  $$('.provider-btn').forEach(btn => {
    btn.addEventListener('click', async () => {
      $$('.provider-btn').forEach(b => { b.disabled = true })
      setError('')

      const { error } = await supabase.auth.linkIdentity({
        provider: btn.dataset.provider,
        options:  { redirectTo: REDIRECT_URL }
      })

      if (error) {
        $$('.provider-btn').forEach(b => { b.disabled = false })
        setError('Could not connect. Please try again.')
      }
      // On success Supabase redirects the browser — no further handling needed
    })
  })
}

// ── Magic link ────────────────────────────────────────────────────────────

function initMagicLink() {
  const toggle  = $('magic-info-toggle')
  const infoBox = $('magic-info-box')
  const sendBtn = $('magic-btn')
  const input   = $('email-input')

  toggle?.addEventListener('click', () => {
    const expanded = toggle.getAttribute('aria-expanded') === 'true'
    toggle.setAttribute('aria-expanded', String(!expanded))
    infoBox.hidden = expanded
  })

  sendBtn?.addEventListener('click', async () => {
    const email = input?.value.trim() || ''
    if (!email) { input?.focus(); return }

    sendBtn.disabled    = true
    sendBtn.textContent = 'Sending…'
    setError('')

    const { error } = await supabase.auth.signInWithOtp({
      email,
      options: { emailRedirectTo: REDIRECT_URL }
    })

    if (error) {
      sendBtn.disabled    = false
      sendBtn.textContent = 'Send link'
      setError('Could not send. Please check the email and try again.')
      return
    }

    const sentEl = $('sent-email')
    if (sentEl) sentEl.textContent = email
    showView('view-sent')
  })

  $('try-again-btn')?.addEventListener('click', () => {
    showView('view-main')
    if (sendBtn)  { sendBtn.disabled = false; sendBtn.textContent = 'Send link' }
    if (input)    input.value = ''
    setError('')
  })
}

// ── Boot ──────────────────────────────────────────────────────────────────

async function init() {
  if (location.hash.includes('access_token=')) {
    handleCallback()
    return
  }

  const { data: { user } } = await supabase.auth.getUser()

  if (user && !user.is_anonymous) {
    showView('view-already-saved')
    return
  }

  showView('view-main')
  initProviders()
  initMagicLink()
}

init()
