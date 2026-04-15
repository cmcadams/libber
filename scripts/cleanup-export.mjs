import fs from 'node:fs/promises'
import path from 'node:path'
import { createClient } from '@supabase/supabase-js'

const supabaseUrl = process.env.SUPABASE_URL || process.env.VITE_SUPABASE_URL
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY

if (!supabaseUrl || !serviceRoleKey) {
  console.error('Missing env vars. Required: SUPABASE_URL (or VITE_SUPABASE_URL) and SUPABASE_SERVICE_ROLE_KEY')
  process.exit(1)
}

const supabase = createClient(supabaseUrl, serviceRoleKey, {
  auth: { persistSession: false, autoRefreshToken: false }
})

const tables = [
  'profiles',
  'stores',
  'store_memberships',
  'store_staff',
  'store_managers',
  'store_staff_applicants',
  'points_ledger'
]

function stamp() {
  const d = new Date()
  const pad = n => String(n).padStart(2, '0')
  return `${d.getUTCFullYear()}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}-${pad(d.getUTCHours())}${pad(d.getUTCMinutes())}${pad(d.getUTCSeconds())}Z`
}

async function exportTable(table, outDir) {
  const rows = []
  const pageSize = 1000
  let from = 0

  while (true) {
    const to = from + pageSize - 1
    const { data, error } = await supabase
      .from(table)
      .select('*')
      .range(from, to)

    if (error) throw new Error(`${table}: ${error.message}`)

    const batch = data || []
    rows.push(...batch)

    if (batch.length < pageSize) break
    from += pageSize
  }

  const filePath = path.join(outDir, `${table}.json`)
  await fs.writeFile(filePath, JSON.stringify(rows, null, 2) + '\n', 'utf8')
  return rows.length
}

async function exportAuthUsers(outDir) {
  const users = []
  let page = 1
  const perPage = 1000

  while (true) {
    const { data, error } = await supabase.auth.admin.listUsers({ page, perPage })
    if (error) throw new Error(`auth.users: ${error.message}`)

    const batch = data?.users || []
    users.push(...batch)

    if (batch.length < perPage) break
    page += 1
  }

  await fs.writeFile(path.join(outDir, 'auth.users.json'), JSON.stringify(users, null, 2) + '\n', 'utf8')
  return users.length
}

async function run() {
  const outDir = path.join('backups', `cleanup-${stamp()}`)
  await fs.mkdir(outDir, { recursive: true })

  console.log(`Writing backup to ${outDir}`)

  for (const table of tables) {
    const count = await exportTable(table, outDir)
    console.log(`- ${table}: ${count} rows`) 
  }

  const authCount = await exportAuthUsers(outDir)
  console.log(`- auth.users: ${authCount} rows`)
  console.log('Backup complete.')
}

run().catch(err => {
  console.error(err.message || err)
  process.exit(1)
})
