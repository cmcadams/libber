-- Full reset: deletes ALL data from every table including auth users.
-- Run in the Supabase SQL editor (Dashboard → SQL Editor).
-- There is no undo. Export a backup first if needed.

DELETE FROM public.points_ledger;
DELETE FROM public.store_memberships;
DELETE FROM public.store_staff;
DELETE FROM public.store_managers;
DELETE FROM public.store_reward_rules;
DELETE FROM public.stores;
DELETE FROM public.profiles;
DELETE FROM public.admins;
DELETE FROM auth.users;
