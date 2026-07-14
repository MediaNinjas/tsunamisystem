-- Fix RLS so promo codes can be created/redeemed from the app.
-- Safe: adds policies + admin RPC. Does not delete data.

alter table public.codes enable row level security;

-- Ensure multi-use columns exist (no-op if you already ran the earlier migration).
alter table public.codes
  add column if not exists max_uses integer not null default 1;
alter table public.codes
  add column if not exists use_count integer not null default 0;

-- Clear old conflicting policies by name if we re-run this script.
drop policy if exists "codes_select_authenticated" on public.codes;
drop policy if exists "codes_insert_authenticated" on public.codes;
drop policy if exists "codes_update_authenticated" on public.codes;
drop policy if exists "codes_insert_admin_unused" on public.codes;
drop policy if exists "codes_insert_own_receipt" on public.codes;
drop policy if exists "Allow authenticated read" on public.codes;
drop policy if exists "Allow authenticated insert" on public.codes;
drop policy if exists "Allow authenticated update" on public.codes;

-- Anyone signed in can look up a code (needed to redeem).
create policy "codes_select_authenticated"
  on public.codes for select
  to authenticated
  using (true);

-- Admin can create unused promo / multi-use codes.
create policy "codes_insert_admin_unused"
  on public.codes for insert
  to authenticated
  with check (
    used = false
    and coalesce(use_count, 0) = 0
    and (auth.jwt() ->> 'email') = 'serano9@gmail.com'
  );

-- Signed-in users can insert a used receipt row for themselves (PayPal path).
create policy "codes_insert_own_receipt"
  on public.codes for insert
  to authenticated
  with check (
    used = true
    and used_by = auth.uid()
  );

-- Signed-in users can redeem (bump use_count / mark used).
create policy "codes_update_authenticated"
  on public.codes for update
  to authenticated
  using (true)
  with check (true);

-- Bulletproof admin create path (bypasses RLS via security definer).
create or replace function public.admin_create_promo_code(p_max_uses integer default 1)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := auth.jwt() ->> 'email';
  v_code text;
  v_chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_seg text;
  v_i int;
  v_max int := greatest(coalesce(p_max_uses, 1), 1);
begin
  if v_email is distinct from 'serano9@gmail.com' then
    raise exception 'not authorized';
  end if;

  v_seg := '';
  for v_i in 1..4 loop
    v_seg := v_seg || substr(v_chars, 1 + floor(random() * length(v_chars))::int, 1);
  end loop;
  v_code := 'TSU-' || v_seg || '-';
  v_seg := '';
  for v_i in 1..4 loop
    v_seg := v_seg || substr(v_chars, 1 + floor(random() * length(v_chars))::int, 1);
  end loop;
  v_code := v_code || v_seg;

  insert into public.codes (code, used, max_uses, use_count)
  values (v_code, false, v_max, 0);

  return v_code;
end;
$$;

revoke all on function public.admin_create_promo_code(integer) from public;
grant execute on function public.admin_create_promo_code(integer) to authenticated;
