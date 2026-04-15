import { state } from '../state/state.js'

export function renderAdmin() {
  const el = document.getElementById('staff-list')
  if (!el) return

  if (!state.allStaff?.length) {
    el.innerHTML = '<p>No staff found</p>'
    return
  }

  el.innerHTML = ''

  state.allStaff.forEach(staff => {
    const card = document.createElement('div')
    card.className = 'staff-card'
    card.innerHTML = `
      <h2>${staff.stores?.name || 'Unknown Store'}</h2>
      <p>${staff.user_id}</p>
    `
    card.addEventListener('click', () => {
      localStorage.setItem('libber_staff', JSON.stringify({
        userId: staff.user_id,
        storeId: staff.store_id,
        storeName: staff.stores?.name
      }))
      window.location.href = '/staffpage.html'
    })
    el.appendChild(card)
  })
}
