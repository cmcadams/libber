# Libber — Claude Guidelines

## Always follow established patterns

Before suggesting any approach, check how the same problem is already solved in this codebase and follow that pattern. Do not introduce new patterns without a clear reason.

## Security pattern: RPCs as the only write path

All write operations go through Supabase RPCs, never direct table inserts/deletes/updates from the client. RLS blocks direct writes. The auth/permission check lives inside the RPC.

Examples already in place:
- `award_points` — verifies caller is staff before writing to `points_ledger`
- `admin_assign_manager` — service role only
- `approve_staff_applicant` — verifies caller is manager
- `apply_for_staff` — uses `auth.uid()` to enforce caller identity

Any new write operation follows this same pattern: new RPC + RLS policy. Never suggest service role keys in the browser, Edge Functions, or any other approach unless the RPC pattern genuinely cannot solve the problem.

## Stack

- Vite + vanilla JS (no frameworks)
- Supabase (anon auth, RLS, RPCs)
- Two deployed apps: `apps/customer/` and `apps/staff/`
- `adminstart.html` is local-only, never deployed

## Auth

Anonymous Supabase auth. All identity and role checks are tied to `auth.uid()` inside RPCs or RLS policies. No login system.

## No service role key in the browser

Even for the local-only admin tool. If an operation needs elevated privileges, it goes through an RPC.
