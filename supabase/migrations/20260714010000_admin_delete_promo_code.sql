-- Allow admin to delete promo codes from Settings.

create or replace function public.admin_delete_promo_code(p_code text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := auth.jwt() ->> 'email';
  v_code text := upper(trim(coalesce(p_code, '')));
  v_deleted int := 0;
begin
  if v_email is distinct from 'serano9@gmail.com' then
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

  return true;
end;
$$;

revoke all on function public.admin_delete_promo_code(text) from public;
grant execute on function public.admin_delete_promo_code(text) to authenticated;
