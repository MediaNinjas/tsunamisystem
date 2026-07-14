-- codes.type is NOT NULL with CHECK (type IN ('free','paid')).
-- Admin/RPC inserts were omitting type → not-null violation.
-- Also add optional payment receipt columns used by app/webhook.

alter table public.codes
  alter column type set default 'free';

alter table public.codes
  add column if not exists stripe_session_id text;

alter table public.codes
  add column if not exists paypal_order_id text;

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

  insert into public.codes (code, used, max_uses, use_count, type)
  values (v_code, false, v_max, 0, 'free');

  return v_code;
end;
$$;

revoke all on function public.admin_create_promo_code(integer) from public;
grant execute on function public.admin_create_promo_code(integer) to authenticated;
