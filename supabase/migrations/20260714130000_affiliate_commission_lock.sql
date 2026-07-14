-- Per-affiliate locked commission + admin-editable default rate.

create table if not exists public.app_settings (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);

insert into public.app_settings (key, value)
values ('affiliate_default_commission_cents', '500'::jsonb)
on conflict (key) do nothing;

alter table public.affiliates
  add column if not exists commission_cents integer
    check (commission_cents is null or commission_cents >= 0);

alter table public.app_settings enable row level security;

drop policy if exists "app_settings_admin_all" on public.app_settings;
create policy "app_settings_admin_all" on public.app_settings
  for all to authenticated
  using ((auth.jwt() ->> 'email') = 'serano9@gmail.com')
  with check ((auth.jwt() ->> 'email') = 'serano9@gmail.com');

-- Authenticated can read the default commission (shown on apply form).
drop policy if exists "app_settings_read_affiliate_default" on public.app_settings;
create policy "app_settings_read_affiliate_default" on public.app_settings
  for select to authenticated
  using (key = 'affiliate_default_commission_cents');

create or replace function public.get_affiliate_default_commission_cents()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v int;
begin
  select coalesce((value #>> '{}')::int, 500)
    into v
  from public.app_settings
  where key = 'affiliate_default_commission_cents';
  return greatest(coalesce(v, 500), 0);
end;
$$;

create or replace function public.admin_set_affiliate_default_commission(p_dollars numeric)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin text := auth.jwt() ->> 'email';
  v_cents int;
begin
  if v_admin is distinct from 'serano9@gmail.com' then
    raise exception 'not authorized';
  end if;
  if p_dollars is null or p_dollars < 0 or p_dollars > 1000 then
    raise exception 'commission must be between 0 and 1000 dollars';
  end if;
  v_cents := round(p_dollars * 100)::int;

  insert into public.app_settings (key, value, updated_at)
  values ('affiliate_default_commission_cents', to_jsonb(v_cents), now())
  on conflict (key) do update
    set value = excluded.value,
        updated_at = now();

  return v_cents;
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
  v_comm int := public.get_affiliate_default_commission_cents();
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
    affiliate_code, created_by, ai_verdict, ai_summary, commission_cents
  ) values (
    v_uid, v_name, v_email, v_status,
    nullif(trim(p_payout_paypal), ''),
    nullif(trim(p_payout_venmo), ''),
    nullif(trim(p_payout_cashapp), ''),
    v_code, 'admin_manual',
    case when v_status = 'approved' then 'approve' else 'pending' end,
    case when v_status = 'approved' then 'Manually added by admin.' else 'Manually added — pending review.' end,
    case when v_status = 'approved' then v_comm else null end
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
  v_comm int;
  v_default int := public.get_affiliate_default_commission_cents();
begin
  if v_admin is distinct from 'serano9@gmail.com' then
    raise exception 'not authorized';
  end if;
  if v_status not in ('pending', 'approved', 'denied') then
    raise exception 'invalid status';
  end if;

  select affiliate_code, commission_cents
    into v_code, v_comm
  from public.affiliates
  where id = p_id;
  if not found then
    raise exception 'affiliate not found';
  end if;

  if v_status = 'approved' then
    if v_code is null or v_code = '' then
      v_code := public._affiliate_make_code();
    end if;
    -- Lock rate on approve only when unset (new approve or after resubmit cleared it).
    if v_comm is null then
      v_comm := v_default;
    end if;
  end if;

  update public.affiliates set
    status = v_status,
    affiliate_code = case when v_status = 'approved' then v_code else affiliate_code end,
    commission_cents = case
      when v_status = 'approved' then v_comm
      else commission_cents
    end,
    updated_at = now()
  where id = p_id;

  return true;
end;
$$;

-- Affiliate resubmits → pending again, commission unlocked so next approve uses current default.
create or replace function public.resubmit_affiliate_application(
  p_name text default null,
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
  v_id uuid;
begin
  if v_uid is null or v_email = '' then
    raise exception 'not authenticated';
  end if;

  select id into v_id
  from public.affiliates
  where user_id = v_uid or lower(email) = v_email
  limit 1;

  if v_id is null then
    raise exception 'no affiliate record to resubmit — apply first';
  end if;

  update public.affiliates set
    name = coalesce(nullif(trim(p_name), ''), name),
    website = coalesce(nullif(trim(p_website), ''), website),
    channels = coalesce(nullif(trim(p_channels), ''), channels),
    pitch = coalesce(nullif(trim(p_pitch), ''), pitch),
    traffic_notes = coalesce(nullif(trim(p_traffic_notes), ''), traffic_notes),
    payout_paypal = coalesce(nullif(trim(p_payout_paypal), ''), payout_paypal),
    payout_venmo = coalesce(nullif(trim(p_payout_venmo), ''), payout_venmo),
    payout_cashapp = coalesce(nullif(trim(p_payout_cashapp), ''), payout_cashapp),
    status = 'pending',
    commission_cents = null,
    ai_verdict = 'pending',
    ai_summary = 'Resubmitted — awaiting review at current commission rate.',
    updated_at = now()
  where id = v_id;

  return v_id;
end;
$$;

revoke all on function public.get_affiliate_default_commission_cents() from public;
grant execute on function public.get_affiliate_default_commission_cents() to authenticated;

revoke all on function public.admin_set_affiliate_default_commission(numeric) from public;
grant execute on function public.admin_set_affiliate_default_commission(numeric) to authenticated;

revoke all on function public.resubmit_affiliate_application(text, text, text, text, text, text, text, text) from public;
grant execute on function public.resubmit_affiliate_application(text, text, text, text, text, text, text, text) to authenticated;
