-- Affiliate sales attribution, holds, ready queue, payout batches, statements.

alter table public.affiliates
  add column if not exists payouts_held boolean not null default false;

-- Expand commission status: owed → ready (≥ threshold) → paid
alter table public.affiliate_commissions
  drop constraint if exists affiliate_commissions_status_check;

alter table public.affiliate_commissions
  add constraint affiliate_commissions_status_check
  check (status in ('owed', 'ready', 'paid'));

create table if not exists public.affiliate_payout_batches (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('manual_push', 'threshold_auto', 'monthly_statement')),
  period_label text,
  total_cents integer not null default 0,
  affiliate_count integer not null default 0,
  dropbox_path text,
  payload jsonb,
  notes text,
  created_by uuid,
  created_at timestamptz not null default now()
);

alter table public.affiliate_payout_batches enable row level security;

drop policy if exists "payout_batches_admin" on public.affiliate_payout_batches;
create policy "payout_batches_admin" on public.affiliate_payout_batches
  for all to authenticated
  using ((auth.jwt() ->> 'email') = 'serano9@gmail.com')
  with check ((auth.jwt() ->> 'email') = 'serano9@gmail.com');

insert into public.app_settings (key, value)
values ('affiliate_auto_push', 'true'::jsonb)
on conflict (key) do nothing;

insert into public.app_settings (key, value)
values ('affiliate_payout_threshold_cents', '2500'::jsonb)
on conflict (key) do nothing;

create or replace function public.get_affiliate_payout_threshold_cents()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare v int;
begin
  select coalesce((value #>> '{}')::int, 2500) into v
  from public.app_settings where key = 'affiliate_payout_threshold_cents';
  return greatest(coalesce(v, 2500), 0);
end;
$$;

create or replace function public.get_affiliate_auto_push()
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v text;
begin
  select coalesce(value #>> '{}', 'true') into v
  from public.app_settings where key = 'affiliate_auto_push';
  return lower(coalesce(v, 'true')) in ('true', '1', 'yes');
end;
$$;

create or replace function public.admin_set_affiliate_auto_push(p_enabled boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if (auth.jwt() ->> 'email') is distinct from 'serano9@gmail.com' then
    raise exception 'not authorized';
  end if;
  insert into public.app_settings (key, value, updated_at)
  values ('affiliate_auto_push', to_jsonb(coalesce(p_enabled, true)), now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return coalesce(p_enabled, true);
end;
$$;

create or replace function public.admin_set_affiliate_hold(p_id uuid, p_held boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if (auth.jwt() ->> 'email') is distinct from 'serano9@gmail.com' then
    raise exception 'not authorized';
  end if;
  update public.affiliates set
    payouts_held = coalesce(p_held, false),
    updated_at = now()
  where id = p_id;
  if not found then raise exception 'affiliate not found'; end if;

  -- If holding, pull ready rows back to owed.
  if coalesce(p_held, false) then
    update public.affiliate_commissions
      set status = 'owed'
    where affiliate_id = p_id and status = 'ready';
  end if;
  return true;
end;
$$;

-- Credit a paid unlock to an affiliate code (no free promos).
create or replace function public.attribute_paid_sale(
  p_buyer_id uuid,
  p_ref text default null,
  p_stripe_session text default null,
  p_paypal_order text default null,
  p_sale_cents integer default 2000
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ref text := upper(trim(coalesce(p_ref, '')));
  v_aff public.affiliates%rowtype;
  v_comm int;
  v_id uuid;
  v_sale int := greatest(coalesce(p_sale_cents, 2000), 0);
begin
  if p_buyer_id is null then
    raise exception 'buyer required';
  end if;
  -- Callers: Stripe webhook (service_role) or the paying user after PayPal capture.
  if coalesce(auth.jwt() ->> 'role', '') is distinct from 'service_role' then
    if auth.uid() is distinct from p_buyer_id then
      raise exception 'not authorized';
    end if;
  end if;
  if v_ref = '' then
    return null;
  end if;
  if p_stripe_session is null and p_paypal_order is null then
    raise exception 'payment reference required';
  end if;
  if p_paypal_order is not null and not exists (
    select 1 from public.codes
    where paypal_order_id = p_paypal_order
      and used_by = p_buyer_id
      and type = 'paid'
  ) then
    raise exception 'paypal order not found for buyer';
  end if;
  if p_stripe_session is not null and coalesce(auth.jwt() ->> 'role', '') is distinct from 'service_role' then
    if not exists (
      select 1 from public.codes
      where stripe_session_id = p_stripe_session
        and used_by = p_buyer_id
        and type = 'paid'
    ) then
      raise exception 'stripe session not found for buyer';
    end if;
  end if;

  select * into v_aff
  from public.affiliates
  where affiliate_code = v_ref
    and status = 'approved'
  limit 1;

  if not found then
    return null;
  end if;

  -- Block self-referral
  if v_aff.user_id is not null and v_aff.user_id = p_buyer_id then
    return null;
  end if;

  if p_stripe_session is not null and exists (
    select 1 from public.affiliate_commissions where stripe_session_id = p_stripe_session
  ) then
    return null;
  end if;
  if p_paypal_order is not null and exists (
    select 1 from public.affiliate_commissions where paypal_order_id = p_paypal_order
  ) then
    return null;
  end if;

  v_comm := coalesce(v_aff.commission_cents, public.get_affiliate_default_commission_cents());

  insert into public.affiliate_commissions (
    affiliate_id, buyer_user_id, amount_cents, sale_amount_cents, status,
    stripe_session_id, paypal_order_id
  ) values (
    v_aff.id, p_buyer_id, v_comm, v_sale, 'owed',
    p_stripe_session, p_paypal_order
  )
  returning id into v_id;

  perform public.refresh_affiliate_payout_queue(v_aff.id);
  return v_id;
end;
$$;

create or replace function public.refresh_affiliate_payout_queue(p_affiliate_id uuid default null)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_threshold int := public.get_affiliate_payout_threshold_cents();
  v_count int := 0;
  v_updated int := 0;
  r record;
  v_owed int;
begin
  for r in
    select a.id, a.payouts_held
    from public.affiliates a
    where a.status = 'approved'
      and (p_affiliate_id is null or a.id = p_affiliate_id)
  loop
    if r.payouts_held then
      update public.affiliate_commissions
        set status = 'owed'
      where affiliate_id = r.id and status = 'ready';
      continue;
    end if;

    select coalesce(sum(amount_cents), 0) into v_owed
    from public.affiliate_commissions
    where affiliate_id = r.id and status in ('owed', 'ready');

    if v_owed >= v_threshold then
      update public.affiliate_commissions
        set status = 'ready'
      where affiliate_id = r.id and status = 'owed';
      get diagnostics v_updated = row_count;
      v_count := v_count + v_updated;
    else
      update public.affiliate_commissions
        set status = 'owed'
      where affiliate_id = r.id and status = 'ready';
    end if;
  end loop;
  return v_count;
end;
$$;

-- Returns JSON packaging ready commissions for Dropbox + marks them paid.
create or replace function public.admin_push_ready_payouts(p_affiliate_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin text := auth.jwt() ->> 'email';
  v_uid uuid := auth.uid();
  v_rows jsonb := '[]'::jsonb;
  v_total int := 0;
  v_count int := 0;
  v_batch_id uuid;
  r record;
  v_item jsonb;
  v_ids uuid[];
begin
  if v_admin is distinct from 'serano9@gmail.com' then
    raise exception 'not authorized';
  end if;

  perform public.refresh_affiliate_payout_queue(p_affiliate_id);

  for r in
    select a.id as affiliate_id, a.name, a.email, a.affiliate_code,
           a.payout_paypal, a.payout_venmo, a.payout_cashapp, a.payouts_held,
           coalesce(sum(c.amount_cents), 0)::int as amount_cents,
           array_agg(c.id) as commission_ids
    from public.affiliates a
    join public.affiliate_commissions c on c.affiliate_id = a.id and c.status = 'ready'
    where a.payouts_held = false
      and (p_affiliate_id is null or a.id = p_affiliate_id)
    group by a.id
  loop
    v_item := jsonb_build_object(
      'affiliate_id', r.affiliate_id,
      'name', r.name,
      'email', r.email,
      'code', r.affiliate_code,
      'amount_cents', r.amount_cents,
      'amount_dollars', round(r.amount_cents / 100.0, 2),
      'payout_paypal', r.payout_paypal,
      'payout_venmo', r.payout_venmo,
      'payout_cashapp', r.payout_cashapp,
      'preferred_method', case
        when r.payout_paypal is not null then 'paypal'
        when r.payout_venmo is not null then 'venmo'
        when r.payout_cashapp is not null then 'cashapp'
        else 'unknown'
      end
    );
    v_rows := v_rows || jsonb_build_array(v_item);
    v_total := v_total + r.amount_cents;
    v_count := v_count + 1;
    v_ids := coalesce(v_ids, array[]::uuid[]) || r.commission_ids;
  end loop;

  if v_count < 1 then
    return jsonb_build_object('ok', true, 'pushed', 0, 'total_cents', 0, 'items', '[]'::jsonb);
  end if;

  insert into public.affiliate_payout_batches (
    kind, period_label, total_cents, affiliate_count, payload, notes, created_by
  ) values (
    case when p_affiliate_id is null then 'threshold_auto' else 'manual_push' end,
    to_char(now() at time zone 'UTC', 'YYYY-MM'),
    v_total, v_count, jsonb_build_object('items', v_rows),
    'Payout packet generated — send via affiliate PayPal/Venmo/Cash App handles.',
    v_uid
  )
  returning id into v_batch_id;

  update public.affiliate_commissions set
    status = 'paid',
    paid_at = now(),
    payout_note = 'batch:' || v_batch_id::text
  where id = any(v_ids);

  return jsonb_build_object(
    'ok', true,
    'batch_id', v_batch_id,
    'pushed', v_count,
    'total_cents', v_total,
    'items', v_rows,
    'period', to_char(now() at time zone 'UTC', 'YYYY-MM')
  );
end;
$$;

create or replace function public.admin_generate_monthly_statement(p_year int, p_month int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin text := auth.jwt() ->> 'email';
  v_uid uuid := auth.uid();
  v_start timestamptz;
  v_end timestamptz;
  v_label text;
  v_rows jsonb := '[]'::jsonb;
  v_total int := 0;
  v_count int := 0;
  v_batch_id uuid;
  r record;
begin
  if v_admin is distinct from 'serano9@gmail.com' then
    raise exception 'not authorized';
  end if;
  if p_year is null or p_month is null or p_month < 1 or p_month > 12 then
    raise exception 'valid year and month required';
  end if;

  v_start := make_timestamptz(p_year, p_month, 1, 0, 0, 0, 'UTC');
  v_end := v_start + interval '1 month';
  v_label := lpad(p_year::text, 4, '0') || '-' || lpad(p_month::text, 2, '0');

  for r in
    select a.name, a.email, a.affiliate_code,
           c.amount_cents, c.sale_amount_cents, c.status, c.created_at, c.paid_at,
           c.stripe_session_id, c.paypal_order_id, c.payout_note
    from public.affiliate_commissions c
    join public.affiliates a on a.id = c.affiliate_id
    where c.created_at >= v_start and c.created_at < v_end
    order by c.created_at
  loop
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'name', r.name,
      'email', r.email,
      'code', r.affiliate_code,
      'amount_cents', r.amount_cents,
      'sale_cents', r.sale_amount_cents,
      'status', r.status,
      'created_at', r.created_at,
      'paid_at', r.paid_at,
      'stripe_session_id', r.stripe_session_id,
      'paypal_order_id', r.paypal_order_id,
      'note', r.payout_note
    ));
    v_total := v_total + coalesce(r.amount_cents, 0);
    v_count := v_count + 1;
  end loop;

  insert into public.affiliate_payout_batches (
    kind, period_label, total_cents, affiliate_count, payload, notes, created_by
  ) values (
    'monthly_statement', v_label, v_total, v_count,
    jsonb_build_object('period', v_label, 'items', v_rows),
    'Monthly affiliate statement',
    v_uid
  ) returning id into v_batch_id;

  return jsonb_build_object(
    'ok', true,
    'batch_id', v_batch_id,
    'period', v_label,
    'rows', v_count,
    'total_cents', v_total,
    'items', v_rows
  );
end;
$$;

create or replace function public.admin_list_payout_batches(p_limit int default 30)
returns setof public.affiliate_payout_batches
language plpgsql
security definer
set search_path = public
as $$
begin
  if (auth.jwt() ->> 'email') is distinct from 'serano9@gmail.com' then
    raise exception 'not authorized';
  end if;
  return query
    select * from public.affiliate_payout_batches
    order by created_at desc
    limit greatest(coalesce(p_limit, 30), 1);
end;
$$;

revoke all on function public.get_affiliate_payout_threshold_cents() from public;
grant execute on function public.get_affiliate_payout_threshold_cents() to authenticated;
revoke all on function public.get_affiliate_auto_push() from public;
grant execute on function public.get_affiliate_auto_push() to authenticated;
revoke all on function public.admin_set_affiliate_auto_push(boolean) from public;
grant execute on function public.admin_set_affiliate_auto_push(boolean) to authenticated;
revoke all on function public.admin_set_affiliate_hold(uuid, boolean) from public;
grant execute on function public.admin_set_affiliate_hold(uuid, boolean) to authenticated;
revoke all on function public.attribute_paid_sale(uuid, text, text, text, integer) from public;
grant execute on function public.attribute_paid_sale(uuid, text, text, text, integer) to authenticated;
revoke all on function public.refresh_affiliate_payout_queue(uuid) from public;
grant execute on function public.refresh_affiliate_payout_queue(uuid) to authenticated;
revoke all on function public.admin_push_ready_payouts(uuid) from public;
grant execute on function public.admin_push_ready_payouts(uuid) to authenticated;
revoke all on function public.admin_generate_monthly_statement(integer, integer) from public;
grant execute on function public.admin_generate_monthly_statement(integer, integer) to authenticated;
revoke all on function public.admin_list_payout_batches(integer) from public;
grant execute on function public.admin_list_payout_batches(integer) to authenticated;
