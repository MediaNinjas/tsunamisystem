-- Apply current standard commission rate to every affiliate (admin override).

create or replace function public.admin_apply_default_commission_to_all()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin text := auth.jwt() ->> 'email';
  v_default int := public.get_affiliate_default_commission_cents();
  v_count int := 0;
begin
  if v_admin is distinct from 'serano9@gmail.com' then
    raise exception 'not authorized';
  end if;

  update public.affiliates set
    commission_cents = v_default,
    updated_at = now()
  where coalesce(commission_cents, -1) is distinct from v_default
     or commission_cents is null;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.admin_apply_default_commission_to_all() from public;
grant execute on function public.admin_apply_default_commission_to_all() to authenticated;
