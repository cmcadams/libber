-- 01-schema.sql
--
-- All tables, indexes, seed data, storage bucket, and realtime publication.
-- Every column is baked in from the start — no ALTER TABLE needed in later files.
--
-- Run order: FIRST. All other files depend on these tables existing.
-- Safe to re-run: CREATE TABLE IF NOT EXISTS, INSERT … ON CONFLICT DO NOTHING,
--                 CREATE INDEX IF NOT EXISTS throughout.
--
-- Audit fixes applied:
--   CRITICAL  Removed admins_user_id_idx — redundant (user_id is the PK;
--             a primary key already creates an implicit unique index)
--   CRITICAL  Added ledger_user_store_time_idx on
--             points_ledger(user_id, store_id, created_at DESC) — covers the
--             most-queried pattern in the system (balance lookup and history);
--             without it every balance read is a full table scan on an
--             append-only table
--   CRITICAL  Reduced store_reward_rules.kind CHECK to ('award', 'redeem');
--             'bonus_reason' and 'bonus_amount' had no RPC handler in
--             award_points — dead configuration that cannot be used by any
--             client path; removed until the feature is properly built
--   IMPORTANT Added CHECK (char_length(trim(label)) > 0) to store_reward_rules
--   IMPORTANT Added CHECK (max_bonus_points IS NULL OR max_bonus_points >= 1)
--             to stores — 0 would silently block all bonus awards
--   IMPORTANT Added CHECK (deleted_at IS NULL OR is_active = false) to stores
--             — schema-enforced invariant: a deletion timestamp requires the
--             store to be archived; prevents inconsistent soft-delete state
--   IMPORTANT Added CHECK (points != 0) to points_ledger — a zero-point row
--             would corrupt the running_balance sequence without any RPC catching it
--   IMPORTANT Added UNIQUE (store_id, name) to store_outlets — prevents
--             duplicate outlet names within a store (staff picker confusion)
--   MINOR     Renamed ab_variants.text → display_text; 'text' is a PostgreSQL
--             type name and causes parsing ambiguity in some tools; the JSON
--             key returned by load_customer_home remains 'text' (aliased in RPC)
--   MINOR     Added CHECK (position IN ('top', 'middle', 'bottom')) to
--             ab_variants — position was a free-text field with no constraints

-- ── admins ────────────────────────────────────────────────────────────────────
-- Managed via service role only (never written by client code).

CREATE TABLE IF NOT EXISTS public.admins (
  user_id    uuid        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.admins ENABLE ROW LEVEL SECURITY;

-- ── profiles ──────────────────────────────────────────────────────────────────
-- One row per auth.users row, created by the on_auth_user_created trigger.
-- public_id is the human-readable display ID shown to staff (e.g. "ABZ 123 456").

CREATE TABLE IF NOT EXISTS public.profiles (
  user_id                  uuid        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  public_id                text        NOT NULL UNIQUE,
  save_prompt_variant      text,
  interaction_count        integer     NOT NULL DEFAULT 0,
  one_time_prompt_shown_at timestamptz,
  prompt_dismissed_at      timestamptz,
  account_linked_at        timestamptz,
  created_at               timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

-- ── stores ────────────────────────────────────────────────────────────────────
-- Soft-delete: is_active = false + deleted_at = now() via admin_archive_store.
-- Reversed via admin_restore_store: is_active = true + deleted_at = NULL.
-- CHECK enforces that deleted_at being set implies the store is archived.

CREATE TABLE IF NOT EXISTS public.stores (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name             text        NOT NULL CHECK (char_length(trim(name)) > 0),
  max_bonus_points integer     CHECK (max_bonus_points IS NULL OR max_bonus_points >= 1),
  logo_path        text,
  logo_updated_at  timestamptz,
  is_active        boolean     NOT NULL DEFAULT true,
  deleted_at       timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CHECK (deleted_at IS NULL OR is_active = false)
);

ALTER TABLE public.stores ENABLE ROW LEVEL SECURITY;

-- ── store_memberships ─────────────────────────────────────────────────────────
-- is_active = false when a customer leaves (unjoin_store) or is removed by a
-- manager. join_store reactivates an existing row via ON CONFLICT DO UPDATE.

CREATE TABLE IF NOT EXISTS public.store_memberships (
  user_id    uuid        NOT NULL REFERENCES auth.users(id)    ON DELETE CASCADE,
  store_id   uuid        NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
  is_active  boolean     NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, store_id)
);

ALTER TABLE public.store_memberships ENABLE ROW LEVEL SECURITY;

-- ── store_staff ───────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.store_staff (
  user_id    uuid        NOT NULL REFERENCES auth.users(id)    ON DELETE CASCADE,
  store_id   uuid        NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, store_id)
);

ALTER TABLE public.store_staff ENABLE ROW LEVEL SECURITY;

-- ── store_managers ────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.store_managers (
  user_id    uuid        NOT NULL REFERENCES auth.users(id)    ON DELETE CASCADE,
  store_id   uuid        NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, store_id)
);

ALTER TABLE public.store_managers ENABLE ROW LEVEL SECURITY;

-- ── store_reward_rules ────────────────────────────────────────────────────────
-- kind values:
--   'award'  — a predefined earn rule; award_points validates kind = 'award'
--              when p_points > 0 and a rule_id is supplied
--   'redeem' — a predefined redemption rule; award_points validates kind = 'redeem'
--              when p_points < 0; stored points value is positive (the magnitude)
--
-- 'bonus_reason' and 'bonus_amount' were removed. They were accepted by the
-- schema but rejected by award_points (which only handles 'award' and 'redeem').
-- No client path could use them. Add a numbered migration when the feature ships.

CREATE TABLE IF NOT EXISTS public.store_reward_rules (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id   uuid        NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
  label      text        NOT NULL CHECK (char_length(trim(label)) > 0),
  points     integer     NOT NULL,
  kind       text        NOT NULL CHECK (kind IN ('award', 'redeem')),
  sort_order integer     NOT NULL DEFAULT 0,
  is_active  boolean     NOT NULL DEFAULT true,
  is_pinned  boolean     NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.store_reward_rules ENABLE ROW LEVEL SECURITY;

-- ── store_outlets ─────────────────────────────────────────────────────────────
-- Every store must have at least one outlet (enforced by admin_create_store and
-- admin_delete_outlet). The advisory lock in admin_delete_outlet (namespace 1001)
-- prevents two concurrent deletes from racing past the count check.
-- UNIQUE (store_id, name): duplicate outlet names within a store are rejected at
-- the schema level; admin_create_outlet and admin_update_outlet benefit from this.

CREATE TABLE IF NOT EXISTS public.store_outlets (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id   uuid        NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
  name       text        NOT NULL CHECK (char_length(trim(name)) > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (store_id, name)
);

ALTER TABLE public.store_outlets ENABLE ROW LEVEL SECURITY;

-- ── points_ledger ─────────────────────────────────────────────────────────────
-- Append-only. running_balance is always computed server-side inside award_points
-- / adjust_points — the client never sends a balance value.
-- points != 0: a zero-point row would corrupt the running_balance chain without
-- any visible error; both award_points and adjust_points also enforce this in code,
-- but the table constraint holds even for service-role SQL editor inserts.
-- created_by is captured for audit purposes but never returned to clients.

CREATE TABLE IF NOT EXISTS public.points_ledger (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid        NOT NULL REFERENCES auth.users(id)          ON DELETE CASCADE,
  store_id        uuid        NOT NULL REFERENCES public.stores(id)        ON DELETE CASCADE,
  outlet_id       uuid        REFERENCES public.store_outlets(id)          ON DELETE SET NULL,
  points          integer     NOT NULL CHECK (points != 0),
  reason          text        NOT NULL,
  created_by      uuid        REFERENCES auth.users(id)                    ON DELETE SET NULL,
  running_balance integer     NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.points_ledger ENABLE ROW LEVEL SECURITY;

-- ── ab_variants ───────────────────────────────────────────────────────────────
-- Seed-managed. Written via SQL editor / this script, not via client RPCs.
-- Weighted reservoir sampling (Efraimidis-Spirakis) in create_profile() assigns
-- each new user to a variant proportionally to its weight.
-- display_text: renamed from 'text' (a PostgreSQL type name) to avoid ambiguity.
-- position CHECK: only the three values the client layout engine understands.

CREATE TABLE IF NOT EXISTS public.ab_variants (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  test_name    text        NOT NULL,
  variant      text        NOT NULL,
  display_text text        NOT NULL,
  position     text        NOT NULL DEFAULT 'middle'
               CHECK (position IN ('top', 'middle', 'bottom')),
  is_active    boolean     NOT NULL DEFAULT true,
  weight       integer     NOT NULL DEFAULT 50 CHECK (weight >= 0),
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (test_name, variant)
);

ALTER TABLE public.ab_variants ENABLE ROW LEVEL SECURITY;

-- Initial save_prompt variants — must exist before any user is created so that
-- the create_profile trigger can assign a variant.
INSERT INTO public.ab_variants (test_name, variant, display_text, position, weight)
VALUES
  ('save_prompt', 'A', 'Save your points',        'middle', 50),
  ('save_prompt', 'B', 'Don''t lose your points', 'middle', 50)
ON CONFLICT (test_name, variant) DO NOTHING;

-- ── Indexes ───────────────────────────────────────────────────────────────────

-- RBAC lookup indexes — one per role-check pattern used in auth helpers.
-- admins_user_id_idx deliberately omitted: user_id IS the primary key on admins;
-- a primary key already creates an implicit unique B-tree index. A second index
-- is redundant and wastes space.

CREATE INDEX IF NOT EXISTS store_managers_user_store_idx
  ON public.store_managers (user_id, store_id);

CREATE INDEX IF NOT EXISTS store_staff_user_store_idx
  ON public.store_staff (user_id, store_id);

-- Covers the is_active filter on every store lookup.
CREATE INDEX IF NOT EXISTS stores_is_active_idx
  ON public.stores (is_active);

-- Covers the active-member filter in load_store_members / admin_load_store_members.
CREATE INDEX IF NOT EXISTS store_memberships_store_active_idx
  ON public.store_memberships (store_id, is_active);

-- Partial unique index: at most one active membership row per (user, store).
-- join_store uses ON CONFLICT (user_id, store_id) DO UPDATE (the PK conflict);
-- this index enforces the active-uniqueness invariant separately and makes it
-- visible to the query planner for load_customer_home's membership filter.
CREATE UNIQUE INDEX IF NOT EXISTS active_membership_unique
  ON public.store_memberships (user_id, store_id)
  WHERE is_active = true;

-- Critical covering index for the balance-lookup and history-fetch pattern.
-- award_points, adjust_points, load_customer_home (correlated subquery per
-- membership), load_points_history, and load_member_recent_transactions all run:
--   SELECT ... FROM points_ledger
--   WHERE user_id = X AND store_id = Y
--   ORDER BY created_at DESC LIMIT N;
-- Without this index every call is a full table scan on an append-only table.
CREATE INDEX IF NOT EXISTS ledger_user_store_time_idx
  ON public.points_ledger (user_id, store_id, created_at DESC);

-- ── Realtime ──────────────────────────────────────────────────────────────────
-- Enables Supabase Realtime INSERT events on points_ledger.
-- The client subscribes to its own rows (RLS: user_id = auth.uid()); on receipt
-- it calls load_customer_home() to refresh — the payload itself is ignored.

ALTER PUBLICATION supabase_realtime ADD TABLE public.points_ledger;

-- ── Storage ───────────────────────────────────────────────────────────────────
-- Public bucket for store logo images.
-- Path convention enforced by admin_set_store_logo: stores/{store_id}/logo.webp

INSERT INTO storage.buckets (id, name, public)
VALUES ('store-logos', 'store-logos', true)
ON CONFLICT (id) DO NOTHING;
