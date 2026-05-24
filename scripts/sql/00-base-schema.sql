-- 00-base-schema.sql
--
-- Creates the seven core tables for a fresh Supabase database.
-- Feature columns (soft-delete flags, logo fields, A/B columns, etc.) are
-- added by ALTER TABLE in later numbered scripts — keep this file to base
-- columns only so each ALTER TABLE script remains individually idempotent.
--
-- Run order: this file MUST execute before all others.
-- Safe to re-run — all statements use IF NOT EXISTS.
-- Run in Supabase SQL Editor (Dashboard → SQL Editor).
--
-- Tables created here (no applicant tables — applicant system removed):
--   profiles, stores, store_memberships, store_staff, store_managers,
--   store_reward_rules, points_ledger

-- ── profiles ──────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.profiles (
  user_id    uuid        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  public_id  text        NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

-- ── stores ────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.stores (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name       text        NOT NULL CHECK (char_length(trim(name)) > 0),
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.stores ENABLE ROW LEVEL SECURITY;

-- ── store_memberships ─────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.store_memberships (
  user_id    uuid        NOT NULL REFERENCES auth.users(id)    ON DELETE CASCADE,
  store_id   uuid        NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
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

CREATE TABLE IF NOT EXISTS public.store_reward_rules (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id   uuid        NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
  label      text        NOT NULL,
  points     integer     NOT NULL,
  kind       text        NOT NULL CHECK (kind IN ('award', 'redeem')),
  sort_order integer     NOT NULL DEFAULT 0,
  is_active  boolean     NOT NULL DEFAULT true,
  is_pinned  boolean     NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.store_reward_rules ENABLE ROW LEVEL SECURITY;

-- ── points_ledger ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.points_ledger (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid        NOT NULL REFERENCES auth.users(id)    ON DELETE CASCADE,
  store_id        uuid        NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
  points          integer     NOT NULL,
  reason          text        NOT NULL,
  created_by      uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  running_balance integer     NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.points_ledger ENABLE ROW LEVEL SECURITY;
