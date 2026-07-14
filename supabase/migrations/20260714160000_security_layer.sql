-- Tsunami security layer: real is_admin flag, admin audit log, hardened RLS on
-- profiles/cards/codes, rate-limited promo redemption RPC, PayPal unlock RPC,
-- affiliate commission dedupe indexes, and admin_* functions migrated off of
-- hardcoded email checks onto public.is_tsunami_admin().
--
-- Safe: additive only. No DROP TABLE / TRUNCATE / DELETE of existing rows.
-- Re-runnable: uses if not exists / create or replace / drop policy if exists.

-- ============================================================================
-- 1. profiles.is_admin
-- ============================================================================

alter table public.profiles
  add column if not exists is_admin boolean not null default false;

-- ============================================================================
-- 2. Seed the bootstrap admin by email (one-time; new function bodies below
--    read is_admin instead of hardcoding this email).
--    Wrapped with the privileged flag so this stays re-runnable even after the
--    profiles_protect_privileged trigger (section 5) exists on a later re-run.
-- ============================================================================

select set_config('tsunami.allow_privileged', '1', true);

update public.profiles
set is_admin = true
where id in (
  select id from auth.users where lower(email) = 'serano9@gmail.com'
);

-- ============================================================================
-- 3. is_tsunami_admin() helper + admin_audit_log + log_admin_action()
-- ============================================================================

create or replace function public.is_tsunami_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select p.is_admin from public.profiles p where p.id = auth.uid()), false);
$$;

revoke all on function public.is_tsunami_admin() from public;
grant execute on function public.is_tsunami_admin() to authenticated;

create table if not exists public.admin_audit_log (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid,
  action text not null,
  meta jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists admin_audit_log_created_at_idx
  on public.admin_audit_log (created_at desc);
create index if not exists admin_audit_log_actor_idx
  on public.admin_audit_log (actor_id);

alter table public.admin_audit_log enable row level security;

drop policy if exists "admin_audit_log_admin_select" on public.admin_audit_log;
create policy "admin_audit_log_admin_select"
  on public.admin_audit_log for select
  to authenticated
  using (public.is_tsunami_admin());

-- No insert/update/delete policies on purpose: rows can only be written by
-- log_admin_action() (security definer) or the service role (edge functions).

create or replace function public.log_admin_action(p_action text, p_meta jsonb default '{}'::jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.is_tsunami_admin() then
    insert into public.admin_audit_log (actor_id, action, meta)
    values (auth.uid(), coalesce(p_action, 'unknown'), coalesce(p_meta, '{}'::jsonb));
  end if;
end;
$$;

revoke all on function public.log_admin_action(text, jsonb) from public;
grant execute on function public.log_admin_action(text, jsonb) to authenticated;

-- ============================================================================
-- 5. Harden profiles RLS.
--    unlocked/is_admin can only change via a security-definer RPC that sets
--    tsunami.allow_privileged for the duration of its own transaction — the
--    trigger blocks any other UPDATE (including a client PATCH) that touches
--    those two columns.
-- ============================================================================

alter table public.profiles enable row level security;

drop policy if exists "profiles_select_own" on public.profiles;
drop policy if exists "profiles_update_own" on public.profiles;
drop policy if exists "profiles_insert_own" on public.profiles;
drop policy if exists "Users can view own profile" on public.profiles;
drop policy if exists "Users can update own profile" on public.profiles;
drop policy if exists "Users can insert own profile" on public.profiles;
drop policy if exists "Enable read access for all users" on public.profiles;
drop policy if exists "Allow authenticated read" on public.profiles;
drop policy if exists "Allow authenticated update" on public.profiles;

create policy "profiles_select_own"
  on public.profiles for select
  to authenticated
  using (id = auth.uid() or public.is_tsunami_admin());

create policy "profiles_update_own"
  on public.profiles for update
  to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

create or replace function public.profiles_protect_privileged()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if (new.unlocked is distinct from old.unlocked or new.is_admin is distinct from old.is_admin)
     and coalesce(current_setting('tsunami.allow_privileged', true), '') is distinct from '1'
     and coalesce(auth.role(), '') is distinct from 'service_role' then
    raise exception 'unlocked and is_admin may only be changed by server-side functions';
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_protect_privileged on public.profiles;
create trigger profiles_protect_privileged
  before update on public.profiles
  for each row
  execute function public.profiles_protect_privileged();

-- Stripe webhook helper (service_role / security definer) — still works even if
-- a future trigger change forgets to allow Auth role service_role.
create or replace function public.service_unlock_profile(p_user_id uuid, p_code text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(auth.role(), '') is distinct from 'service_role'
     and coalesce(auth.jwt() ->> 'role', '') is distinct from 'service_role' then
    raise exception 'not authorized';
  end if;
  perform set_config('tsunami.allow_privileged', '1', true);
  insert into public.profiles (id, unlocked, code_used, is_admin)
  values (p_user_id, true, p_code, false)
  on conflict (id) do update
    set unlocked = true,
        code_used = excluded.code_used;
  return true;
end;
$$;

revoke all on function public.service_unlock_profile(uuid, text) from public;
-- Invoked by stripe-webhook with the service role key (PostgREST role = service_role).
grant execute on function public.service_unlock_profile(uuid, text) to service_role;

-- ============================================================================
-- 6. Cards RLS — one row per user_id holding a card_data jsonb array.
-- ============================================================================

alter table public.cards enable row level security;

drop policy if exists "cards_select_own" on public.cards;
drop policy if exists "cards_insert_own" on public.cards;
drop policy if exists "cards_update_own" on public.cards;
drop policy if exists "cards_delete_own" on public.cards;
drop policy if exists "Allow authenticated read" on public.cards;
drop policy if exists "Allow authenticated insert" on public.cards;
drop policy if exists "Allow authenticated update" on public.cards;
drop policy if exists "Allow authenticated delete" on public.cards;

create policy "cards_select_own"
  on public.cards for select
  to authenticated
  using (user_id = auth.uid() or public.is_tsunami_admin());

create policy "cards_insert_own"
  on public.cards for insert
  to authenticated
  with check (user_id = auth.uid());

create policy "cards_update_own"
  on public.cards for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy "cards_delete_own"
  on public.cards for delete
  to authenticated
  using (user_id = auth.uid());

-- ============================================================================
-- 7. Codes RLS harden — admin insert now checks is_tsunami_admin(); redemption
--    can no longer go through an open client UPDATE, only via redeem_promo_code().
-- ============================================================================

alter table public.codes enable row level security;

drop policy if exists "codes_insert_admin_unused" on public.codes;
create policy "codes_insert_admin_unused"
  on public.codes for insert
  to authenticated
  with check (
    used = false
    and coalesce(use_count, 0) = 0
    and public.is_tsunami_admin()
  );

-- codes_select_authenticated and codes_insert_own_receipt are unchanged from
-- 20260713210000_codes_rls_admin_rpc.sql — left in place.

drop policy if exists "codes_update_authenticated" on public.codes;

-- ============================================================================
-- 8. redeem_promo_code(p_code) — rate-limited, atomic, security definer.
-- ============================================================================

create table if not exists public.promo_redeem_attempts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  attempted_at timestamptz not null default now()
);

create index if not exists promo_redeem_attempts_user_time_idx
  on public.promo_redeem_attempts (user_id, attempted_at desc);

alter table public.promo_redeem_attempts enable row level security;

drop policy if exists "promo_redeem_attempts_admin_select" on public.promo_redeem_attempts;
create policy "promo_redeem_attempts_admin_select"
  on public.promo_redeem_attempts for select
  to authenticated
  using (public.is_tsunami_admin());

-- No client insert policy: rows are only written by redeem_promo_code() below.

create or replace function public.redeem_promo_code(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_code text := upper(trim(coalesce(p_code, '')));
  v_recent int;
  v_use_count int;
  v_max_uses int;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;
  if v_code = '' then
    raise exception 'code required';
  end if;

  select count(*) into v_recent
  from public.promo_redeem_attempts
  where user_id = v_uid
    and attempted_at > now() - interval '15 minutes';

  if v_recent >= 12 then
    raise exception 'too many attempts — please wait a few minutes and try again';
  end if;

  -- Log the attempt before validating so brute-forced/invalid codes still count
  -- toward the rate limit above.
  insert into public.promo_redeem_attempts (user_id) values (v_uid);

  select use_count, max_uses into v_use_count, v_max_uses
  from public.codes
  where code = v_code
  for update;

  if not found then
    raise exception 'invalid code';
  end if;

  if coalesce(v_use_count, 0) >= coalesce(v_max_uses, 1) then
    raise exception 'code has been fully redeemed';
  end if;

  update public.codes
  set use_count = use_count + 1,
      used = (use_count + 1) >= max_uses,
      used_by = coalesce(used_by, v_uid),
      used_at = coalesce(used_at, now())
  where code = v_code
    and use_count = v_use_count;

  if not found then
    raise exception 'code redemption conflict — please try again';
  end if;

  perform set_config('tsunami.allow_privileged', '1', true);
  insert into public.profiles (id, unlocked, code_used, is_admin)
  values (v_uid, true, v_code, false)
  on conflict (id) do update
    set unlocked = true,
        code_used = excluded.code_used;

  return jsonb_build_object('ok', true, 'code', v_code);
end;
$$;

revoke all on function public.redeem_promo_code(text) from public;
grant execute on function public.redeem_promo_code(text) to authenticated;

-- ============================================================================
-- 9. complete_paypal_unlock(p_order_id, p_code) — security definer.
-- ============================================================================

create or replace function public.complete_paypal_unlock(p_order_id text, p_code text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_order text := trim(coalesce(p_order_id, ''));
  v_code text := upper(trim(coalesce(p_code, '')));
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;
  if v_order = '' then
    raise exception 'paypal order id required';
  end if;

  if v_code = '' then
    v_code := 'PPL-' || upper(substr(regexp_replace(v_order, '[^A-Za-z0-9]', '', 'g'), 1, 12));
  end if;

  if not exists (select 1 from public.codes where paypal_order_id = v_order) then
    insert into public.codes (code, used, used_by, used_at, paypal_order_id, max_uses, use_count, type)
    values (v_code, true, v_uid, now(), v_order, 1, 1, 'paid');
  end if;

  perform set_config('tsunami.allow_privileged', '1', true);
  insert into public.profiles (id, unlocked, code_used, is_admin)
  values (v_uid, true, v_code, false)
  on conflict (id) do update
    set unlocked = true,
        code_used = coalesce(public.profiles.code_used, excluded.code_used);

  return jsonb_build_object('ok', true, 'order_id', v_order);
end;
$$;

revoke all on function public.complete_paypal_unlock(text, text) from public;
grant execute on function public.complete_paypal_unlock(text, text) to authenticated;

-- ============================================================================
-- 10. Dedupe affiliate commission attribution per payment reference.
-- ============================================================================

create unique index if not exists affiliate_commissions_stripe_session_uidx
  on public.affiliate_commissions (stripe_session_id)
  where stripe_session_id is not null;

create unique index if not exists affiliate_commissions_paypal_order_uidx
  on public.affiliate_commissions (paypal_order_id)
  where paypal_order_id is not null;

-- Needed by delete-account edge function to soft-delete an affiliate record
-- (payout handles removed) without breaking historical commission rows.
alter table public.affiliates
  add column if not exists deleted_at timestamptz;

-- ============================================================================
-- 11. Recreate admin_* functions: is_tsunami_admin() instead of hardcoded
--     email, and log_admin_action() on every mutation.
-- ============================================================================

-- from 20260714000000_admin_custom_promo_code.sql
create or replace function public.admin_create_promo_code(
  p_max_uses integer default 1,
  p_code text default null
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
  v_chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_seg text;
  v_i int;
  v_max int := greatest(coalesce(p_max_uses, 1), 1);
  v_custom text := upper(trim(coalesce(p_code, '')));
begin
  if not public.is_tsunami_admin() then
    raise exception 'not authorized';
  end if;

  if v_custom <> '' then
    v_custom := regexp_replace(v_custom, '\s+', '', 'g');
    if char_length(v_custom) < 4 or char_length(v_custom) > 32 then
      raise exception 'custom code must be 4-32 characters';
    end if;
    if v_custom !~ '^[A-Z0-9]+(-[A-Z0-9]+)*$' then
      raise exception 'custom code may only use letters, numbers, and hyphens';
    end if;
    if exists (select 1 from public.codes where code = v_custom) then
      raise exception 'that code already exists';
    end if;
    v_code := v_custom;
  else
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
  end if;

  insert into public.codes (code, used, max_uses, use_count, type)
  values (v_code, false, v_max, 0, 'free');

  perform public.log_admin_action('admin_create_promo_code', jsonb_build_object('code', v_code, 'max_uses', v_max));

  return v_code;
end;
$$;

revoke all on function public.admin_create_promo_code(integer, text) from public;
grant execute on function public.admin_create_promo_code(integer, text) to authenticated;

-- from 20260714010000_admin_delete_promo_code.sql
create or replace function public.admin_delete_promo_code(p_code text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text := upper(trim(coalesce(p_code, '')));
  v_deleted int := 0;
begin
  if not public.is_tsunami_admin() then
    raise exception 'not authorized';
  end if;

  if v_code = '' then
    raise exception 'code required';
  end if;

  delete from public.codes
  where code = v_code
    and type = 'free';

  get diagnostics v_deleted = row_count;
  if v_deleted < 1 then
    raise exception 'code not found';
  end if;

  perform public.log_admin_action('admin_delete_promo_code', jsonb_build_object('code', v_code));

  return true;
end;
$$;

revoke all on function public.admin_delete_promo_code(text) from public;
grant execute on function public.admin_delete_promo_code(text) to authenticated;

-- from 20260714130000_affiliate_commission_lock.sql (latest admin_create_affiliate)
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
  v_name text := trim(coalesce(p_name, ''));
  v_email text := lower(trim(coalesce(p_email, '')));
  v_id uuid;
  v_status text := case when coalesce(p_approve, true) then 'approved' else 'pending' end;
  v_code text := null;
  v_uid uuid;
  v_comm int := public.get_affiliate_default_commission_cents();
begin
  if not public.is_tsunami_admin() then
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

  perform public.log_admin_action('admin_create_affiliate', jsonb_build_object('affiliate_id', v_id, 'email', v_email, 'status', v_status));

  return v_id;
end;
$$;

revoke all on function public.admin_create_affiliate(text, text, text, text, text, boolean) from public;
grant execute on function public.admin_create_affiliate(text, text, text, text, text, boolean) to authenticated;

-- from 20260714130000_affiliate_commission_lock.sql (latest admin_set_affiliate_status)
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
  v_status text := lower(trim(coalesce(p_status, '')));
  v_code text;
  v_comm int;
  v_default int := public.get_affiliate_default_commission_cents();
begin
  if not public.is_tsunami_admin() then
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

  perform public.log_admin_action('admin_set_affiliate_status', jsonb_build_object('affiliate_id', p_id, 'status', v_status));

  return true;
end;
$$;

revoke all on function public.admin_set_affiliate_status(uuid, text) from public;
grant execute on function public.admin_set_affiliate_status(uuid, text) to authenticated;

-- from 20260714120000_affiliates.sql
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
  v_verdict text := lower(trim(coalesce(p_verdict, '')));
begin
  if not public.is_tsunami_admin() then
    raise exception 'not authorized';
  end if;
  if v_verdict not in ('approve', 'deny', 'pending') then
    raise exception 'invalid verdict';
  end if;

  update public.affiliates set
    ai_verdict = v_verdict,
    ai_summary = nullif(trim(p_summary), ''),
    ai_researched_at = now(),
    status = case
      when status = 'pending' and v_verdict = 'approve' then 'pending'
      when status = 'pending' and v_verdict = 'deny' then 'pending'
      else status
    end,
    updated_at = now()
  where id = p_id;

  if not found then
    raise exception 'affiliate not found';
  end if;

  perform public.log_admin_action('admin_set_affiliate_ai', jsonb_build_object('affiliate_id', p_id, 'verdict', v_verdict));

  return true;
end;
$$;

revoke all on function public.admin_set_affiliate_ai(uuid, text, text) from public;
grant execute on function public.admin_set_affiliate_ai(uuid, text, text) to authenticated;

-- from 20260714120000_affiliates.sql
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
  v_count int := 0;
begin
  if not public.is_tsunami_admin() then
    raise exception 'not authorized';
  end if;

  update public.affiliate_commissions set
    status = 'paid',
    paid_at = now(),
    payout_note = nullif(trim(p_note), '')
  where affiliate_id = p_affiliate_id
    and status = 'owed';

  get diagnostics v_count = row_count;

  perform public.log_admin_action('admin_record_affiliate_payout', jsonb_build_object('affiliate_id', p_affiliate_id, 'rows', v_count));

  return v_count;
end;
$$;

revoke all on function public.admin_record_affiliate_payout(uuid, text) from public;
grant execute on function public.admin_record_affiliate_payout(uuid, text) to authenticated;

-- from 20260714130000_affiliate_commission_lock.sql
create or replace function public.admin_set_affiliate_default_commission(p_dollars numeric)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cents int;
begin
  if not public.is_tsunami_admin() then
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

  perform public.log_admin_action('admin_set_affiliate_default_commission', jsonb_build_object('cents', v_cents));

  return v_cents;
end;
$$;

revoke all on function public.admin_set_affiliate_default_commission(numeric) from public;
grant execute on function public.admin_set_affiliate_default_commission(numeric) to authenticated;

-- from 20260714140000_affiliate_apply_rate_all.sql
create or replace function public.admin_apply_default_commission_to_all()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_default int := public.get_affiliate_default_commission_cents();
  v_count int := 0;
begin
  if not public.is_tsunami_admin() then
    raise exception 'not authorized';
  end if;

  update public.affiliates set
    commission_cents = v_default,
    updated_at = now()
  where coalesce(commission_cents, -1) is distinct from v_default
     or commission_cents is null;

  get diagnostics v_count = row_count;

  perform public.log_admin_action('admin_apply_default_commission_to_all', jsonb_build_object('cents', v_default, 'rows', v_count));

  return v_count;
end;
$$;

revoke all on function public.admin_apply_default_commission_to_all() from public;
grant execute on function public.admin_apply_default_commission_to_all() to authenticated;

-- from 20260714150000_affiliate_payouts_statements.sql
create or replace function public.admin_set_affiliate_auto_push(p_enabled boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_tsunami_admin() then
    raise exception 'not authorized';
  end if;
  insert into public.app_settings (key, value, updated_at)
  values ('affiliate_auto_push', to_jsonb(coalesce(p_enabled, true)), now())
  on conflict (key) do update set value = excluded.value, updated_at = now();

  perform public.log_admin_action('admin_set_affiliate_auto_push', jsonb_build_object('enabled', coalesce(p_enabled, true)));

  return coalesce(p_enabled, true);
end;
$$;

revoke all on function public.admin_set_affiliate_auto_push(boolean) from public;
grant execute on function public.admin_set_affiliate_auto_push(boolean) to authenticated;

create or replace function public.admin_set_affiliate_hold(p_id uuid, p_held boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_tsunami_admin() then
    raise exception 'not authorized';
  end if;
  update public.affiliates set
    payouts_held = coalesce(p_held, false),
    updated_at = now()
  where id = p_id;
  if not found then raise exception 'affiliate not found'; end if;

  if coalesce(p_held, false) then
    update public.affiliate_commissions
      set status = 'owed'
    where affiliate_id = p_id and status = 'ready';
  end if;

  perform public.log_admin_action('admin_set_affiliate_hold', jsonb_build_object('affiliate_id', p_id, 'held', coalesce(p_held, false)));

  return true;
end;
$$;

revoke all on function public.admin_set_affiliate_hold(uuid, boolean) from public;
grant execute on function public.admin_set_affiliate_hold(uuid, boolean) to authenticated;

create or replace function public.admin_push_ready_payouts(p_affiliate_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_rows jsonb := '[]'::jsonb;
  v_total int := 0;
  v_count int := 0;
  v_batch_id uuid;
  r record;
  v_item jsonb;
  v_ids uuid[];
begin
  if not public.is_tsunami_admin() then
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

  perform public.log_admin_action('admin_push_ready_payouts', jsonb_build_object('batch_id', v_batch_id, 'pushed', v_count, 'total_cents', v_total));

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

revoke all on function public.admin_push_ready_payouts(uuid) from public;
grant execute on function public.admin_push_ready_payouts(uuid) to authenticated;

create or replace function public.admin_generate_monthly_statement(p_year int, p_month int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
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
  if not public.is_tsunami_admin() then
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

  perform public.log_admin_action('admin_generate_monthly_statement', jsonb_build_object('batch_id', v_batch_id, 'period', v_label, 'rows', v_count));

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

revoke all on function public.admin_generate_monthly_statement(integer, integer) from public;
grant execute on function public.admin_generate_monthly_statement(integer, integer) to authenticated;

create or replace function public.admin_list_payout_batches(p_limit int default 30)
returns setof public.affiliate_payout_batches
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_tsunami_admin() then
    raise exception 'not authorized';
  end if;
  return query
    select * from public.affiliate_payout_batches
    order by created_at desc
    limit greatest(coalesce(p_limit, 30), 1);
end;
$$;

revoke all on function public.admin_list_payout_batches(integer) from public;
grant execute on function public.admin_list_payout_batches(integer) to authenticated;

-- ============================================================================
-- 12. Update affiliate / app_settings policies off of the hardcoded email.
-- ============================================================================

drop policy if exists "affiliates_select_own" on public.affiliates;
create policy "affiliates_select_own" on public.affiliates
  for select to authenticated
  using (
    user_id = auth.uid()
    or lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
    or public.is_tsunami_admin()
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
          or public.is_tsunami_admin()
        )
    )
  );

drop policy if exists "app_settings_admin_all" on public.app_settings;
create policy "app_settings_admin_all" on public.app_settings
  for all to authenticated
  using (public.is_tsunami_admin())
  with check (public.is_tsunami_admin());

drop policy if exists "payout_batches_admin" on public.affiliate_payout_batches;
create policy "payout_batches_admin" on public.affiliate_payout_batches
  for all to authenticated
  using (public.is_tsunami_admin())
  with check (public.is_tsunami_admin());

-- ============================================================================
-- 13. Signup trigger: set is_admin explicitly (never inherited/true by default).
-- ============================================================================

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, unlocked, code_used, is_admin)
  values (new.id, false, null, false)
  on conflict (id) do nothing;
  return new;
end;
$$;

-- Trigger on_auth_user_created (created in 20260713000000_profiles_on_signup.sql)
-- already points at public.handle_new_user by name — no need to recreate it.
