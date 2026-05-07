import { supabase } from './supabase.js'
import { $ } from './dom.js'

export async function getAdminContext(storeId = null) {
  const { data: { user } } = await supabase.auth.getUser()

  if (!user) {
    return { user_id: null, public_id: null, is_admin: false, is_store_manager: false, current_store_id: null, current_store_name: null }
  }

  const uid = user.id

  const [
    { data: profile },
    { data: isAdminResult },
    { data: managerRow },
    { data: store }
  ] = await Promise.all([
    supabase.from('profiles').select('public_id').eq('user_id', uid).single(),
    supabase.rpc('is_admin'),
    storeId ? supabase.from('store_managers').select('user_id').eq('user_id', uid).eq('store_id', storeId).maybeSingle() : Promise.resolve({ data: null }),
    storeId ? supabase.from('stores').select('name').eq('id', storeId).single()                                          : Promise.resolve({ data: null })
  ])

  return {
    user_id:          uid,
    public_id:        profile?.public_id        ?? null,
    is_admin:         !!isAdminResult,
    is_store_manager: !!managerRow,
    current_store_id:   storeId,
    current_store_name: store?.name ?? null
  }
}

// ── Rendering ─────────────────────────────────────────────────────────────────

function shortUuid(uuid) {
  return uuid ? `${uuid.slice(0, 8)}…${uuid.slice(-4)}` : '—'
}

async function copyText(text, btn) {
  try {
    await navigator.clipboard.writeText(text)
    const orig = btn.textContent
    btn.textContent = '✔'
    setTimeout(() => { btn.textContent = orig }, 1200)
  } catch { /* clipboard unavailable */ }
}

function bindCopy(el) {
  el?.querySelectorAll('[data-copy]').forEach(btn => {
    btn.addEventListener('click', e => { e.stopPropagation(); copyText(btn.dataset.copy, btn) })
  })
}

export async function refreshDebugUI(storeId = null) {
  const ctx = await getAdminContext(storeId)
  const time = new Date().toLocaleTimeString()

  const ok  = str => `<span class="dbg-ok">${str}</span>`
  const no  = str => `<span class="dbg-no">${str}</span>`
  const adminMark = ctx.is_admin         ? ok('✔') : no('✖')
  const mgrMark   = !storeId             ? '<span class="dbg-dim">—</span>'
                  : ctx.is_store_manager ? ok('✔') : no('✖')

  // ── Fixed overlay ──────────────────────────────────────────────────────────
  const dbg = $('dbg')
  if (dbg) {
    dbg.innerHTML = `
      <div class="dbg-row dbg-head">
        <span>Debug</span>
        <button class="dbg-btn" id="dbgRefresh" title="Refresh">↻</button>
      </div>
      <div class="dbg-row">
        <span class="dbg-lbl">pid</span>
        <span class="dbg-val">${ctx.public_id ?? '—'}</span>
      </div>
      <div class="dbg-row">
        <span class="dbg-lbl">uid</span>
        <span class="dbg-val">${shortUuid(ctx.user_id)}</span>
        ${ctx.user_id ? `<button class="dbg-btn" data-copy="${ctx.user_id}" title="Copy UID">⎘</button>` : ''}
      </div>
      <div class="dbg-row">
        <span class="dbg-lbl">admin</span>
        <span class="dbg-val">${adminMark}</span>
      </div>
      <div class="dbg-row">
        <span class="dbg-lbl">mgr</span>
        <span class="dbg-val">${mgrMark}${ctx.current_store_name ? ' <span class="dbg-dim">' + ctx.current_store_name + '</span>' : ''}</span>
      </div>
      <div class="dbg-time">${time}</div>
    `
    $('dbgRefresh')?.addEventListener('click', () => refreshDebugUI(storeId))
    bindCopy(dbg)
  }

  // ── Header bar ─────────────────────────────────────────────────────────────
  const bar = $('dbgHeader')
  if (bar) {
    const adminBadge = ctx.is_admin ? '<span class="dbg-hbadge dbg-ok">✔ Admin</span>' : '<span class="dbg-hbadge dbg-no">✖ Admin</span>'
    const mgrBadge   = !storeId     ? ''
                     : ctx.is_store_manager
                       ? `<span class="dbg-hbadge dbg-ok">✔ Manager</span>`
                       : `<span class="dbg-hbadge dbg-no">✖ Manager</span>`
    const storePart  = ctx.current_store_name ? `<span class="dbg-hsep">·</span><span class="dbg-hstore">${ctx.current_store_name}</span>` : ''

    bar.innerHTML = `
      <div class="dbg-hleft">
        <span class="dbg-hpid">${ctx.public_id ?? '—'}</span>
        <span class="dbg-hsep">·</span>
        <span class="dbg-huid">${shortUuid(ctx.user_id)}</span>
        ${ctx.user_id ? `<button class="dbg-btn" data-copy="${ctx.user_id}" title="Copy UID">⎘</button>` : ''}
        <span class="dbg-hsep">·</span>
        ${adminBadge}
        ${mgrBadge}
        ${storePart}
      </div>
      <span class="dbg-htime">${time}</span>
    `
    bindCopy(bar)
  }
}

// Auto-refresh on auth state change (handles login + logout)
supabase.auth.onAuthStateChange(() => refreshDebugUI(null))
