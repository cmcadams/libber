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

async function countTable(table) {
  const { count, error } = await supabase.from(table).select('*', { count: 'exact', head: true })
  if (error) return { table, error: error.message }
  return { table, count: count ?? 0 }
}

async function listAuthUsers() {
  const users = []
  let page = 1
  const perPage = 1000

  while (true) {
    const { data, error } = await supabase.auth.admin.listUsers({ page, perPage })
    if (error) return { error: error.message }

    const batch = data?.users || []
    users.push(...batch)

    if (batch.length < perPage) break
    page += 1
  }

  const anonymousCount = users.filter(user => user.is_anonymous).length
  return {
    total: users.length,
    anonymous: anonymousCount,
    identified: users.length - anonymousCount
  }
}

async function run() {
  console.log('Cleanup Preview')
  console.log('==============')
  console.log(`Project: ${supabaseUrl}`)

  for (const table of tables) {
    const result = await countTable(table)
    if (result.error) {
      console.log(`- ${table}: ERROR (${result.error})`)
    } else {
      console.log(`- ${table}: ${result.count}`)
    }
  }

  const users = await listAuthUsers()
  if (users.error) {
    console.log(`- auth.users: ERROR (${users.error})`)
  } else {
    console.log(`- auth.users total: ${users.total}`)
    console.log(`  - anonymous: ${users.anonymous}`)
    console.log(`  - identified: ${users.identified}`)
  }

  console.log('\nNo data changed. This was a preview only.')
}

run().catch(err => {
  console.error(err)
  process.exit(1)
})
