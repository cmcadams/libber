import { createClient } from '@supabase/supabase-js'


const supabase = createClient(
  import.meta.env.VITE_SUPABASE_URL,
  import.meta.env.VITE_SUPABASE_ANON_KEY
)

async function load() {
  const { data, error } = await supabase
    .from('clients')
    .select('*')

  console.log(data, error)
}

load()
