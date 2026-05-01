import { $ } from './dom.js'

export function showConfirm(title, detail) {
  return new Promise(resolve => {
    $('confirmTitle').textContent  = title
    $('confirmDetail').textContent = detail
    $('confirmOverlay').classList.add('open')

    function onOk()     { cleanup(); resolve(true) }
    function onCancel() { cleanup(); resolve(false) }
    function onBackdrop(e) {
      if (e.target === $('confirmOverlay')) { cleanup(); resolve(false) }
    }

    function cleanup() {
      $('confirmOverlay').classList.remove('open')
      $('confirmOk').removeEventListener('click', onOk)
      $('confirmCancel').removeEventListener('click', onCancel)
      $('confirmOverlay').removeEventListener('click', onBackdrop)
    }

    $('confirmOk').addEventListener('click', onOk)
    $('confirmCancel').addEventListener('click', onCancel)
    $('confirmOverlay').addEventListener('click', onBackdrop)
  })
}

export function showAlert(message) {
  return new Promise(resolve => {
    $('alertMessage').textContent = message
    $('alertOverlay').classList.add('open')

    function onOk() { cleanup(); resolve() }
    function onBackdrop(e) {
      if (e.target === $('alertOverlay')) { cleanup(); resolve() }
    }
    function onKey(e) {
      if (e.key === 'Enter' || e.key === 'Escape') { cleanup(); resolve() }
    }

    function cleanup() {
      $('alertOverlay').classList.remove('open')
      $('alertOk').removeEventListener('click', onOk)
      $('alertOverlay').removeEventListener('click', onBackdrop)
      document.removeEventListener('keydown', onKey)
    }

    $('alertOk').addEventListener('click', onOk)
    $('alertOverlay').addEventListener('click', onBackdrop)
    document.addEventListener('keydown', onKey)
    $('alertOk').focus()
  })
}
