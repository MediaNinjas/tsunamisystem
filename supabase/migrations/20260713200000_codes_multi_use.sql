-- Multi-use promo codes (single-use = max_uses 1; early-adopter = e.g. 500).
-- Safe: only ADD columns + backfill defaults. No drops.

alter table public.codes
  add column if not exists max_uses integer not null default 1;

alter table public.codes
  add column if not exists use_count integer not null default 0;

-- Existing rows: if already marked used, treat as fully consumed once.
update public.codes
set
  max_uses = coalesce(nullif(max_uses, 0), 1),
  use_count = case when used then greatest(coalesce(use_count, 0), 1) else coalesce(use_count, 0) end
where true;

comment on column public.codes.max_uses is 'How many times this code can be redeemed (1 = single-use)';
comment on column public.codes.use_count is 'How many successful redemptions so far';
