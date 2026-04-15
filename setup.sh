#!/bin/bash

echo "🚀 Setting up Libber clean architecture..."

# =========================
# CLEAN OLD SRC
# =========================
rm -rf src
mkdir -p src/lib src/state src/services src/ui

# =========================
# SUPABASE CLIENT
# =========================
cat > src/lib/supabase.js << 'EOF'
import { createClient } from '@supabase/supabase-js'

export const supabase = createClient(
  import.meta.env.VITE_SUPABASE_URL,
  import.meta.env.VITE_SUPABASE_ANON_KEY
)
EOF

# =========================
# STATE
# =========================
cat > src/state/store.js << 'EOF'
export const state = {
  user: null,
  stores: [],
  staffStores: [],
  selectedStoreId: null,
  members: []
}
EOF

# =========================
# SERVICES
# =========================

cat > src/services/stores.js << 'EOF'
import { supabase } from '../lib/supabase'
import { state } from '../state/store'

export async function loadStores() {
  const { data } = await supabase.from('stores').select('*')
  state.stores = data || []
}
EOF

cat > src/services/staff.js << 'EOF'
import { supabase } from '../lib/supabase'
import { state } from '../state/store'

export async function loadStaffStores(userId) {
  const { data } = await supabase
    .from('store_staff')
    .select('store_id, stores(name)')
    .eq('user_id', userId)

  state.staffStores = data || []
}
EOF

cat > src/services/members.js << 'EOF'
import { supabase } from '../lib/supabase'
import { state } from '../state/store'

export async function loadMembers(storeId) {
  const { data } = await supabase
    .from('store_memberships')
    .select('user_id')
    .eq('store_id', storeId)

  state.members = data || []
}
EOF

# =========================
# UI
# =========================

cat > src/ui/renderStores.js << 'EOF'
import { state } from '../state/store'
import { supabase } from '../lib/supabase'

export function renderStores() {
  const el = document.getElementById('stores')

  el.innerHTML = `
    <h2>Stores</h2>
    <ul>
      ${state.stores.map(s => `
        <li>
          ${s.name}
          <button onclick="joinStore('${s.id}')">Join</button>
        </li>
      `).join('')}
    </ul>
  `
}

window.joinStore = async (storeId) => {
  await supabase.from('store_memberships').insert({
    user_id: state.user.id,
    store_id: storeId
  })

  alert("Joined store")
}
EOF

cat > src/ui/renderCustomers.js << 'EOF'
import { state } from '../state/store'

export function renderCustomers() {
  const el = document.getElementById('customers')

  if (!state.members.length) {
    el.innerHTML = "<p>No customers</p>"
    return
  }

  el.innerHTML = `
    <h2>Customers</h2>
    <ul>
      ${state.members.map(m => `
        <li>${m.user_id}</li>
      `).join('')}
    </ul>
  `
}
EOF

cat > src/ui/renderStaff.js << 'EOF'
import { state } from '../state/store'
import { supabase } from '../lib/supabase'

export function renderStaff() {
  const el = document.getElementById('staff')

  el.innerHTML = `
    <h2>Staff</h2>

    <select id="storeSelect">
      <option value="">Select store</option>
      ${state.staffStores.map(s => `
        <option value="${s.store_id}">
          ${s.stores?.name}
        </option>
      `).join('')}
    </select>
  `

  document.getElementById('storeSelect')
    .addEventListener('change', async (e) => {
      state.selectedStoreId = e.target.value
    })
}

window.givePoints = async (userId) => {
  await supabase.from('points_ledger').insert({
    user_id: userId,
    store_id: state.selectedStoreId,
    points: 10,
    reason: "staff award",
    created_by: state.user.id
  })

  alert("Points added")
}
EOF

# =========================
# MAIN JS
# =========================

cat > src/main.js << 'EOF'
import { state } from './state/store'

import { supabase } from './lib/supabase'

import { loadStores } from './services/stores'
import { loadStaffStores } from './services/staff'
import { loadMembers } from './services/members'

import { renderStores } from './ui/renderStores'
import { renderCustomers } from './ui/renderCustomers'
import { renderStaff } from './ui/renderStaff'

async function initAuth() {
  const { data } = await supabase.auth.getUser()

  if (!data.user) {
    const { data: anon } = await supabase.auth.signInAnonymously()
    state.user = anon.user
  } else {
    state.user = data.user
  }
}

async function renderAll() {
  renderStores()
  renderCustomers()
  renderStaff()
}

async function init() {
  await initAuth()

  await loadStores()
  await loadStaffStores(state.user.id)

  renderAll()
}

init()
EOF

# =========================
# DONE
# =========================
echo "✅ Libber clean architecture setup complete!"
echo "👉 Run: npm run dev"
