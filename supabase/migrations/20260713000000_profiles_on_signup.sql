-- Ensure every auth user has a profiles row with unlocked = false until they pay/redeem.
-- Safe to run: no DROP/TRUNCATE/DELETE. Only adds missing rows and creates trigger if absent.
-- Run in Supabase SQL Editor (should NOT show the destructive-ops warning).

-- Skip if profiles already exists with your live columns — this is a no-op in that case.
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  unlocked boolean not null default false,
  code_used text
);

alter table public.profiles enable row level security;

-- Add profile rows only for users who don't have one yet.
-- Does NOT change existing profiles (paid users stay unlocked).
insert into public.profiles (id, unlocked, code_used)
select u.id, false, null
from auth.users u
left join public.profiles p on p.id = u.id
where p.id is null;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, unlocked, code_used)
  values (new.id, false, null)
  on conflict (id) do nothing;
  return new;
end;
$$;

-- Create trigger only if it doesn't already exist (avoids DROP).
do $$
begin
  if not exists (
    select 1
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where t.tgname = 'on_auth_user_created'
      and n.nspname = 'auth'
      and c.relname = 'users'
  ) then
    create trigger on_auth_user_created
      after insert on auth.users
      for each row
      execute function public.handle_new_user();
  end if;
end;
$$;
