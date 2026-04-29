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
