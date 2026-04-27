import { $ } from '../lib/dom.js'

let _emailSaved = false
let _animating  = false
let _mounted    = false

function mount() {
  if (_mounted) return
  const btn = $('settings-btn')
  if (!btn) return
  btn.addEventListener('animationend', () => {
    btn.classList.remove('glowing')
    _animating = false
  })
  _mounted = true
}

export function render(data) {
  if (!data) return
  mount()
  if (data.email_saved) _emailSaved = true
}

export function glow() {
  if (_emailSaved || _animating) return
  const btn = $('settings-btn')
  if (!btn) return
  btn.classList.add('glowing')
  _animating = true
}
