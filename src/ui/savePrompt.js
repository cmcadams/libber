// Save prompt module.
// Owns all state and DOM interaction for the account-saving prompt.
// Public API: render(data), glow().

let _visible    = false  // prompt is currently shown
let _emailSaved = false  // user has already saved their email
let _animating  = false  // glow animation is in progress
let _mounted    = false  // animationend listener has been attached

function getEls() {
  return {
    el:  document.getElementById('save-prompt'),
    btn: document.getElementById('save-prompt-btn')
  }
}

// Attaches the animationend listener once. Retries on subsequent calls if the
// DOM was not ready on the first attempt.
function mount() {
  if (_mounted) return
  const { btn } = getEls()
  if (!btn) return
  btn.addEventListener('animationend', () => {
    btn.classList.remove('glowing')
    _animating = false
  })
  _mounted = true
}

function show(text, position) {
  const { el, btn } = getEls()
  if (!el || !btn) return
  btn.textContent     = text
  el.dataset.position = position || 'middle'
  el.classList.add('is-visible')
  _visible = true
}

function hide() {
  if (!_visible) return
  const { el, btn } = getEls()
  if (!el) return
  el.classList.remove('is-visible')
  if (btn) btn.classList.remove('glowing')
  _visible   = false
  _animating = false
}

// Called every time home data arrives (from cache or fresh RPC response).
// Uses 'save_prompt' in data to distinguish a fresh RPC response (key always
// present, even when null) from pre-feature cached data (key absent), so
// stale cache never hides a prompt that was already shown.
export function render(data) {
  if (!data) return
  mount()

  if (data.email_saved) {
    _emailSaved = true
    hide()
    return
  }

  // Key absent → old cache format from before this feature. Leave visibility
  // unchanged — fresh data will arrive shortly and handle it correctly.
  if (!('save_prompt' in data)) return

  // Key present but null → no active variant assigned (or variant deactivated).
  if (!data.save_prompt?.text) {
    hide()
    return
  }

  const { el, btn } = getEls()
  if (!el || !btn) return

  // Update text and position on every call in case the variant config changed.
  btn.textContent     = data.save_prompt.text
  el.dataset.position = data.save_prompt.position || 'middle'

  if (!_visible) {
    el.classList.add('is-visible')
    _visible = true
  }
}

// Triggers the glow animation when new points are detected.
// No-ops when the prompt is hidden, email is saved, or animation is running.
export function glow() {
  if (!_visible || _emailSaved || _animating) return
  const { btn } = getEls()
  if (!btn) return
  btn.classList.add('glowing')
  _animating = true
}
