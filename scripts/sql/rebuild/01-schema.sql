-- 01-schema.sql
--
-- All tables, indexes, seed data, storage bucket, and realtime publication.
-- Every column that existed across the full 00–21 migration chain is baked in
-- here from the start — no ALTER TABLE needed in later files.
--
-- Run order: FIRST. All other files depend on these tables existing.
-- Safe to re-run: CREATE TABLE IF NOT EXISTS, INSERT … ON CONFLICT DO NOTHING,
--                 CREATE INDEX IF NOT EXISTS throughout.

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

CREATE TABLE IF NOT EXISTS public.stores (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name             text        NOT NULL CHECK (char_length(trim(name)) > 0),
  max_bonus_points integer,                     -- NULL = no cap on bonus awards
  logo_path        text,                         -- storage path: stores/{id}/logo.webp
  logo_updated_at  timestamptz,                  -- cache-bust timestamp
  is_active        boolean     NOT NULL DEFAULT true,
  deleted_at       timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now()
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
--   'award'        — a predefined earn rule (e.g. "Buy 10, get 1 free" → +10 pts)
--   'redeem'       — a predefined redemption rule (negative points)
--   'bonus_reason' — a named reason for a free-form bonus award
--   'bonus_amount' — a preset bonus amount (amount chosen at award time)

CREATE TABLE IF NOT EXISTS public.store_reward_rules (
  id         uuid    PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id   uuid    NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
  label      text    NOT NULL,
  points     integer NOT NULL,
  kind       text    NOT NULL CHECK (kind IN ('award', 'redeem', 'bonus_reason', 'bonus_amount')),
  sort_order integer NOT NULL DEFAULT 0,
  is_active  boolean NOT NULL DEFAULT true,
  is_pinned  boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.store_reward_rules ENABLE ROW LEVEL SECURITY;

-- ── store_outlets ─────────────────────────────────────────────────────────────
-- Every store must have at least one outlet (enforced by admin_create_store and
-- admin_delete_outlet). The advisory lock in admin_delete_outlet (namespace 1001)
-- prevents two concurrent deletes from racing past the count check.

CREATE TABLE IF NOT EXISTS public.store_outlets (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id   uuid        NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
  name       text        NOT NULL CHECK (char_length(trim(name)) > 0),
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.store_outlets ENABLE ROW LEVEL SECURITY;

-- ── points_ledger ─────────────────────────────────────────────────────────────
-- Append-only. running_balance is always computed server-side inside award_points
-- / adjust_points — the client never sends a balance value.
-- created_by is in the WAL stream but never returned by any client-facing RPC.

CREATE TABLE IF NOT EXISTS public.points_ledger (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid        NOT NULL REFERENCES auth.users(id)          ON DELETE CASCADE,
  store_id        uuid        NOT NULL REFERENCES public.stores(id)        ON DELETE CASCADE,
  outlet_id       uuid        REFERENCES public.store_outlets(id)          ON DELETE SET NULL,
  points          integer     NOT NULL,
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

CREATE TABLE IF NOT EXISTS public.ab_variants (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  test_name  text        NOT NULL,
  variant    text        NOT NULL,
  text       text        NOT NULL,
  position   text        NOT NULL DEFAULT 'middle',
  is_active  boolean     NOT NULL DEFAULT true,
  weight     integer     NOT NULL DEFAULT 50 CHECK (weight >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (test_name, variant)
);

ALTER TABLE public.ab_variants ENABLE ROW LEVEL SECURITY;

-- Initial save_prompt variants — must exist before any user is created so that
-- the create_profile trigger can assign a variant.
INSERT INTO public.ab_variants (test_name, variant, text, position, weight)
VALUES
  ('save_prompt', 'A', 'Save your points',        'middle', 50),
  ('save_prompt', 'B', 'Don''t lose your points', 'middle', 50)
ON CONFLICT (test_name, variant) DO NOTHING;

-- ── Indexes ───────────────────────────────────────────────────────────────────
-- Performance indexes for the three point-lookup patterns in auth helpers.

CREATE INDEX IF NOT EXISTS admins_user_id_idx
  ON public.admins (user_id);

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
-- join_store uses ON CONFLICT (user_id, store_id) DO UPDATE — this index is
-- complementary; it makes the invariant visible and queryable.
CREATE UNIQUE INDEX IF NOT EXISTS active_membership_unique
  ON public.store_memberships (user_id, store_id)
  WHERE is_active = true;

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
