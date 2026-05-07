import { supabase } from './supabase.js'
import { $ } from './dom.js'
import { escapeHtml } from './escape.js'

// Tracks the last storeId used so TOKEN_REFRESHED can re-render with correct context.
let _lastStoreId = null

export async function getAdminContext(storeId = null) {
  const { data, error: authErr } = await supabase.auth.getUser()
  const user = data?.user

  if (authErr || !user) {
    return { user_id: null, public_id: null, is_admin: false, is_store_manager: false, current_store_id: null, current_store_name: null, errors: { auth: authErr?.message ?? null } }
  }

  const uid = user.id

  const [
    { data: profile,       error: profileError },
    { data: isAdminResult, error: adminError },
    { data: managerRow,    error: managerError },
    { data: store,         error: storeError }
  ] = await Promise.all([
    supabase.from('profiles').select('public_id').eq('user_id', uid).single(),
    supabase.rpc('is_admin'),
    storeId ? supabase.from('store_managers').select('user_id').eq('user_id', uid).eq('store_id', storeId).maybeSingle() : Promise.resolve({ data: null, error: null }),
    storeId ? supabase.from('stores').select('name').eq('id', storeId).single()                                          : Promise.resolve({ data: null, error: null })
  ])

  return {
    user_id:          uid,
    public_id:        profile?.public_id        ?? null,
    is_admin:         !!isAdminResult,
    is_store_manager: !!managerRow,
    current_store_id:   storeId,
    current_store_name: store?.name ?? null,
    errors: {
      profile: profileError?.message ?? null,
      admin:   adminError?.message   ?? null,
      manager: managerError?.message ?? null,
      store:   storeError?.message   ?? null,
    }
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

// Race guard: only the most recent call renders.
let _refreshSeq = 0

export async function refreshDebugUI(storeId = null) {
  _lastStoreId = storeId
  const seq = ++_refreshSeq

  const ctx = await getAdminContext(storeId)
  if (seq !== _refreshSeq) return  // superseded by a newer call

  const hasError = ctx.errors && Object.values(ctx.errors).some(Boolean)
  const time = new Date().toLocaleTimeString()

  const ok  = str => `<span class="dbg-ok">${str}</span>`
  const no  = str => `<span class="dbg-no">${str}</span>`
  const err = str => `<span class="dbg-err">${str}</span>`

  const adminMark = ctx.errors?.admin   ? err('ERR')
                  : ctx.is_admin        ? ok('✔')  : no('✖')
  const mgrMark   = !storeId            ? '<span class="dbg-dim">—</span>'
                  : ctx.errors?.manager ? err('ERR')
                  : ctx.is_store_manager ? ok('✔') : no('✖')

  const safePid   = escapeHtml(ctx.public_id        ?? '—')
  const safeUid   = escapeHtml(shortUuid(ctx.user_id))
  const safeName  = escapeHtml(ctx.current_store_name ?? '')

  // ── Fixed overlay ──────────────────────────────────────────────────────────
  const dbg = $('dbg')
  if (dbg) {
    dbg.innerHTML = `
      <div class="dbg-row dbg-head">
        <span>Debug${hasError ? ' ' + err('!') : ''}</span>
        <button class="dbg-btn" id="dbgRefresh" title="Refresh">↻</button>
      </div>
      <div class="dbg-row">
        <span class="dbg-lbl">pid</span>
        <span class="dbg-val">${ctx.errors?.profile ? err('ERR') : safePid}</span>
      </div>
      <div class="dbg-row">
        <span class="dbg-lbl">uid</span>
        <span class="dbg-val">${safeUid}</span>
        ${ctx.user_id ? `<button class="dbg-btn" data-copy="${escapeHtml(ctx.user_id)}" title="Copy UID">⎘</button>` : ''}
      </div>
      <div class="dbg-row">
        <span class="dbg-lbl">admin</span>
        <span class="dbg-val">${adminMark}</span>
      </div>
      <div class="dbg-row">
        <span class="dbg-lbl">mgr</span>
        <span class="dbg-val">${mgrMark}${safeName ? ' <span class="dbg-dim">' + safeName + '</span>' : ''}</span>
      </div>
      <div class="dbg-time">${time}</div>
    `
    $('dbgRefresh')?.addEventListener('click', () => refreshDebugUI(storeId))
    bindCopy(dbg)
  }

  // ── Header bar ─────────────────────────────────────────────────────────────
  const bar = $('dbgHeader')
  if (bar) {
    const adminBadge = ctx.errors?.admin   ? `<span class="dbg-hbadge dbg-err">${err('ERR')} Admin</span>`
                     : ctx.is_admin        ? '<span class="dbg-hbadge dbg-ok">✔ Admin</span>'
                     :                      '<span class="dbg-hbadge dbg-no">✖ Admin</span>'
    const mgrBadge   = !storeId            ? ''
                     : ctx.errors?.manager ? `<span class="dbg-hbadge dbg-err">${err('ERR')} Manager</span>`
                     : ctx.is_store_manager ? `<span class="dbg-hbadge dbg-ok">✔ Manager</span>`
                     :                       `<span class="dbg-hbadge dbg-no">✖ Manager</span>`
    const storePart  = safeName ? `<span class="dbg-hsep">·</span><span class="dbg-hstore">${safeName}</span>` : ''

    bar.innerHTML = `
      <div class="dbg-hleft">
        <span class="dbg-hpid">${ctx.errors?.profile ? err('ERR') : safePid}</span>
        <span class="dbg-hsep">·</span>
        <span class="dbg-huid">${safeUid}</span>
        ${ctx.user_id ? `<button class="dbg-btn" data-copy="${escapeHtml(ctx.user_id)}" title="Copy UID">⎘</button>` : ''}
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

// Refresh on auth state changes.
// TOKEN_REFRESHED preserves _lastStoreId; only SIGNED_OUT clears it.
supabase.auth.onAuthStateChange((event) => {
  if (event === 'SIGNED_OUT') {
    _lastStoreId = null
    refreshDebugUI(null)
  } else {
    refreshDebugUI(_lastStoreId)
  }
})
