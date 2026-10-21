create table if not exists public.remote_config(key text primary key,value jsonb not null default '[]'::jsonb,updated_at timestamptz not null default now());
alter table public.remote_config enable row level security;
-- Free Remote availability is separate from authentication/device permission.
create or replace function public.remote_is_allowed() returns boolean language sql stable security invoker set search_path='' as $$ select auth.uid() is not null $$;
revoke all on function public.remote_is_allowed() from public,anon;
grant execute on function public.remote_is_allowed() to authenticated;
