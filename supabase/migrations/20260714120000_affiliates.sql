-- Tsunami affiliate program: applications, admin controls, payout handles, commissions.

create table if not exists public.affiliates (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users (id) on delete set null,
  name text not null,
  email text not null,
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'denied')),
  website text,
  channels text,
  pitch text,
  traffic_notes text,
  payout_paypal text,
  payout_venmo text,
  payout_cashapp text,
  affiliate_code text unique,
  ai_verdict text check (ai_verdict is null or ai_verdict in ('approve', 'deny', 'pending')),
  ai_summary text,
  ai_researched_at timestamptz,
  admin_notes text,
  created_by text not null default 'application'
    check (created_by in ('application', 'admin_manual')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists affiliates_status_idx on public.affiliates (status);
create index if not exists affiliates_email_idx on public.affiliates (lower(email));
create index if not exists affiliates_user_id_idx on public.affiliates (user_id);
create index if not exists affiliates_code_idx on public.affiliates (affiliate_code);

create table if not exists public.affiliate_commissions (
  id uuid primary key default gen_random_uuid(),
  affiliate_id uuid not null references public.affiliates (id) on delete cascade,
  buyer_user_id uuid,
  amount_cents integer not null default 500 check (amount_cents >= 0),
  sale_amount_cents integer not null default 2000 check (sale_amount_cents >= 0),
  status text not null default 'owed' check (status in ('owed', 'paid')),
  stripe_session_id text,
  paypal_order_id text,
  paid_at timestamptz,
  payout_note text,
  created_at timestamptz not null default now()
);

create index if not exists affiliate_commissions_affiliate_idx
  on public.affiliate_commissions (affiliate_id, status);

alter table public.affiliates enable row level security;
alter table public.affiliate_commissions enable row level security;

drop policy if exists "affiliates_select_own" on public.affiliates;
create policy "affiliates_select_own" on public.affiliates
  for select to authenticated
  using (
    user_id = auth.uid()
    or lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
    or (auth.jwt() ->> 'email') = 'serano9@gmail.com'
  );

drop policy if exists "affiliates_insert_own" on public.affiliates;
create policy "affiliates_insert_own" on public.affiliates
  for insert to authenticated
  with check (
    created_by = 'application'
    and user_id = auth.uid()
    and status = 'pending'
  );

drop policy if exists "affiliates_update_own_payouts" on public.affiliates;
create policy "affiliates_update_own_payouts" on public.affiliates
  for update to authenticated
  using (
    user_id = auth.uid()
    or lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  )
  with check (
    user_id = auth.uid()
    or lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );

drop policy if exists "commissions_select_own" on public.affiliate_commissions;
create policy "commissions_select_own" on public.affiliate_commissions
  for select to authenticated
  using (
    exists (
      select 1 from public.affiliates a
      where a.id = affiliate_id
        and (
          a.user_id = auth.uid()
          or lower(a.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
          or (auth.jwt() ->> 'email') = 'serano9@gmail.com'
        )
    )
  );

-- Helpers
create or replace function public._affiliate_make_code()
returns text
language plpgsql
as $$
declare
  v_chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_seg text;
  v_i int;
  v_code text;
begin
  loop
    v_seg := '';
    for v_i in 1..4 loop
      v_seg := v_seg || substr(v_chars, 1 + floor(random() * length(v_chars))::int, 1);
    end loop;
    v_code := 'AFF-' || v_seg;
    exit when not exists (select 1 from public.affiliates where affiliate_code = v_code);
  end loop;
  return v_code;
end;
$$;

create or replace function public.submit_affiliate_application(
  p_name text,
  p_website text default null,
  p_channels text default null,
  p_pitch text default null,
  p_traffic_notes text default null,
  p_payout_paypal text default null,
  p_payout_venmo text default null,
  p_payout_cashapp text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_email text := lower(trim(coalesce(auth.jwt() ->> 'email', '')));
  v_name text := trim(coalesce(p_name, ''));
  v_id uuid;
begin
  if v_uid is null or v_email = '' then
    raise exception 'not authenticated';
  end if;
  if v_name = '' then
    raise exception 'name required';
  end if;
  if coalesce(trim(p_website), '') = ''
     and coalesce(trim(p_channels), '') = '' then
    raise exception 'provide a website or social proof link';
  end if;
  if exists (
    select 1 from public.affiliates
    where user_id = v_uid or lower(email) = v_email
  ) then
    raise exception 'you already have an affiliate application';
  end if;

  insert into public.affiliates (
    user_id, name, email, status, website, channels, pitch, traffic_notes,
    payout_paypal, payout_venmo, payout_cashapp, created_by, ai_verdict
  ) values (
    v_uid, v_name, v_email, 'pending',
    nullif(trim(p_website), ''),
    nullif(trim(p_channels), ''),
    nullif(trim(p_pitch), ''),
    nullif(trim(p_traffic_notes), ''),
    nullif(trim(p_payout_paypal), ''),
    nullif(trim(p_payout_venmo), ''),
    nullif(trim(p_payout_cashapp), ''),
    'application',
    'pending'
  )
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.update_my_affiliate_payouts(
  p_payout_paypal text default null,
  p_payout_venmo text default null,
  p_payout_cashapp text default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_email text := lower(trim(coalesce(auth.jwt() ->> 'email', '')));
  v_updated int := 0;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  update public.affiliates set
    payout_paypal = nullif(trim(p_payout_paypal), ''),
    payout_venmo = nullif(trim(p_payout_venmo), ''),
    payout_cashapp = nullif(trim(p_payout_cashapp), ''),
    updated_at = now()
  where user_id = v_uid or lower(email) = v_email;

  get diagnostics v_updated = row_count;
  if v_updated < 1 then
    raise exception 'no affiliate record found';
  end if;
  return true;
end;
$$;

create or replace function public.admin_create_affiliate(
  p_name text,
  p_email text,
  p_payout_paypal text default null,
  p_payout_venmo text default null,
  p_payout_cashapp text default null,
  p_approve boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin text := auth.jwt() ->> 'email';
  v_name text := trim(coalesce(p_name, ''));
  v_email text := lower(trim(coalesce(p_email, '')));
  v_id uuid;
  v_status text := case when coalesce(p_approve, true) then 'approved' else 'pending' end;
  v_code text := null;
  v_uid uuid;
begin
  if v_admin is distinct from 'serano9@gmail.com' then
    raise exception 'not authorized';
  end if;
  if v_name = '' or v_email = '' then
    raise exception 'name and email required';
  end if;
  if exists (select 1 from public.affiliates where lower(email) = v_email) then
    raise exception 'affiliate with that email already exists';
  end if;

  select id into v_uid from auth.users where lower(email) = v_email limit 1;

  if v_status = 'approved' then
    v_code := public._affiliate_make_code();
  end if;

  insert into public.affiliates (
    user_id, name, email, status, payout_paypal, payout_venmo, payout_cashapp,
    affiliate_code, created_by, ai_verdict, ai_summary
  ) values (
    v_uid, v_name, v_email, v_status,
    nullif(trim(p_payout_paypal), ''),
    nullif(trim(p_payout_venmo), ''),
    nullif(trim(p_payout_cashapp), ''),
    v_code, 'admin_manual',
    case when v_status = 'approved' then 'approve' else 'pending' end,
    case when v_status = 'approved' then 'Manually added by admin.' else 'Manually added — pending review.' end
  )
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.admin_set_affiliate_status(
  p_id uuid,
  p_status text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin text := auth.jwt() ->> 'email';
  v_status text := lower(trim(coalesce(p_status, '')));
  v_code text;
begin
  if v_admin is distinct from 'serano9@gmail.com' then
    raise exception 'not authorized';
  end if;
  if v_status not in ('pending', 'approved', 'denied') then
    raise exception 'invalid status';
  end if;

  select affiliate_code into v_code from public.affiliates where id = p_id;
  if not found then
    raise exception 'affiliate not found';
  end if;

  if v_status = 'approved' and (v_code is null or v_code = '') then
    v_code := public._affiliate_make_code();
  end if;

  update public.affiliates set
    status = v_status,
    affiliate_code = case when v_status = 'approved' then v_code else affiliate_code end,
    updated_at = now()
  where id = p_id;

  return true;
end;
$$;

create or replace function public.admin_set_affiliate_ai(
  p_id uuid,
  p_verdict text,
  p_summary text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin text := auth.jwt() ->> 'email';
  v_verdict text := lower(trim(coalesce(p_verdict, '')));
begin
  if v_admin is distinct from 'serano9@gmail.com' then
    raise exception 'not authorized';
  end if;
  if v_verdict not in ('approve', 'deny', 'pending') then
    raise exception 'invalid verdict';
  end if;

  update public.affiliates set
    ai_verdict = v_verdict,
    ai_summary = nullif(trim(p_summary), ''),
    ai_researched_at = now(),
    -- Keep human status in sync only when still pending (don't clobber approve/deny).
    status = case
      when status = 'pending' and v_verdict = 'approve' then 'pending' -- AI suggests; you still click Approve
      when status = 'pending' and v_verdict = 'deny' then 'pending'
      else status
    end,
    updated_at = now()
  where id = p_id;

  if not found then
    raise exception 'affiliate not found';
  end if;
  return true;
end;
$$;

create or replace function public.admin_record_affiliate_payout(
  p_affiliate_id uuid,
  p_note text default null
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin text := auth.jwt() ->> 'email';
  v_count int := 0;
begin
  if v_admin is distinct from 'serano9@gmail.com' then
    raise exception 'not authorized';
  end if;

  update public.affiliate_commissions set
    status = 'paid',
    paid_at = now(),
    payout_note = nullif(trim(p_note), '')
  where affiliate_id = p_affiliate_id
    and status = 'owed';

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.submit_affiliate_application(text, text, text, text, text, text, text, text) from public;
grant execute on function public.submit_affiliate_application(text, text, text, text, text, text, text, text) to authenticated;

revoke all on function public.update_my_affiliate_payouts(text, text, text) from public;
grant execute on function public.update_my_affiliate_payouts(text, text, text) to authenticated;

revoke all on function public.admin_create_affiliate(text, text, text, text, text, boolean) from public;
grant execute on function public.admin_create_affiliate(text, text, text, text, text, boolean) to authenticated;

revoke all on function public.admin_set_affiliate_status(uuid, text) from public;
grant execute on function public.admin_set_affiliate_status(uuid, text) to authenticated;

revoke all on function public.admin_set_affiliate_ai(uuid, text, text) from public;
grant execute on function public.admin_set_affiliate_ai(uuid, text, text) to authenticated;

revoke all on function public.admin_record_affiliate_payout(uuid, text) from public;
grant execute on function public.admin_record_affiliate_payout(uuid, text) to authenticated;
