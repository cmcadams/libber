import { loadAllStaff } from './services/admin.js'
import { renderAdmin } from './ui/renderAdmin.js'

async function init() {
  try {
    await loadAllStaff()
    renderAdmin()
  } catch (err) {
    console.error(err)
    alert('Something went wrong')
  }
}

init()
