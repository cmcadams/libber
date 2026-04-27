import { $ } from '../lib/dom.js'

let _accountLinked = false
let _animating     = false
let _mounted       = false

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
  if (data.account_linked || data.email_saved) _accountLinked = true
}

export function glow() {
  if (_accountLinked || _animating) return
  const btn = $('settings-btn')
  if (!btn) return
  btn.classList.add('glowing')
  _animating = true
}
