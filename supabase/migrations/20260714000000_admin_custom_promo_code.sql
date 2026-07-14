-- Allow admin to set a custom promo code (or leave null/blank for random).

drop function if exists public.admin_create_promo_code(integer);
drop function if exists public.admin_create_promo_code(integer, text);

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
  v_email text := auth.jwt() ->> 'email';
  v_code text;
  v_chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_seg text;
  v_i int;
  v_max int := greatest(coalesce(p_max_uses, 1), 1);
  v_custom text := upper(trim(coalesce(p_code, '')));
begin
  if v_email is distinct from 'serano9@gmail.com' then
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

  return v_code;
end;
$$;

revoke all on function public.admin_create_promo_code(integer, text) from public;
grant execute on function public.admin_create_promo_code(integer, text) to authenticated;
