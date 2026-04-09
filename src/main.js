import { createClient } from '@supabase/supabase-js'



const supabase = createClient(
  'https://flghcbrwqtburdywgcvk.supabase.co',
'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZsZ2hjYnJ3cXRidXJkeXdnY3ZrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU2MDI1MjcsImV4cCI6MjA5MTE3ODUyN30.psbCQaOkCJiVefoK7tKCGW1dsv0gzVUbs-fOdRKztVY'
)


async function load() {
  const { data, error } = await supabase
    .from('clients')
    .select('*')

  console.log(data, error)
}

load()
