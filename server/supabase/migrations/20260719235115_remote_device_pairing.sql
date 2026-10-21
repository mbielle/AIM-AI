-- Socle sécurité du mode remote : APPAIRAGE PAR APPAREIL (round B1).
-- Objectif : un compte compromis (mot de passe volé) ne doit PAS suffire à
-- piloter la machine. Un appareil ne peut agir que s'il a été appairé une fois
-- via un code affiché SUR l'ordinateur (⇒ accès physique requis), et il doit
-- prouver à chaque commande la connaissance d'un secret que lui seul détient.
-- Additif et réversible ; l'INSERT direct sur remote_commands reste autorisé
-- pour l'instant (bascule dans une 2e migration, une fois le web migré).

create extension if not exists pgcrypto;

create table if not exists public.remote_devices (
  id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null default 'Appareil',
  secret_hash text not null,
  paired_at timestamptz not null default now(),
  last_used_at timestamptz,
  expires_at timestamptz,
  revoked_at timestamptz
);
create index if not exists remote_devices_user_idx on public.remote_devices (user_id, revoked_at);

create table if not exists public.remote_pairing_codes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  machine_id uuid not null references public.remote_machines(id) on delete cascade,
  code_hash text not null,
  expires_at timestamptz not null,
  consumed_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists remote_pairing_codes_user_idx on public.remote_pairing_codes (user_id, expires_at);

alter table public.remote_devices enable row level security;
alter table public.remote_pairing_codes enable row level security;

do $$
declare t text;
begin
  foreach t in array array['remote_devices','remote_pairing_codes'] loop
    execute format('create policy %I on public.%I for select using (user_id = auth.uid())', t || '_select_own', t);
    execute format('create policy %I on public.%I for insert with check (user_id = auth.uid())', t || '_insert_own', t);
    execute format('create policy %I on public.%I for update using (user_id = auth.uid()) with check (user_id = auth.uid())', t || '_update_own', t);
    execute format('create policy %I on public.%I for delete using (user_id = auth.uid())', t || '_delete_own', t);
  end loop;
end $$;

create or replace function public.remote_pair_device(
  p_code text,
  p_device_id uuid,
  p_device_secret text,
  p_device_name text default 'Appareil'
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.remote_pairing_codes%rowtype;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'not_authenticated');
  end if;
  if p_device_secret is null or length(p_device_secret) < 32 then
    return jsonb_build_object('ok', false, 'error', 'weak_secret');
  end if;

  select * into v_row from public.remote_pairing_codes
  where user_id = auth.uid()
    and consumed_at is null
    and expires_at > now()
    and code_hash = encode(digest(p_code, 'sha256'), 'hex')
  order by created_at desc
  limit 1;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'invalid_or_expired_code');
  end if;

  update public.remote_pairing_codes set consumed_at = now() where id = v_row.id;

  insert into public.remote_devices (id, user_id, name, secret_hash, expires_at)
  values (
    p_device_id, auth.uid(), coalesce(nullif(p_device_name, ''), 'Appareil'),
    encode(digest(p_device_secret, 'sha256'), 'hex'),
    now() + interval '90 days'
  )
  on conflict (id) do update
    set secret_hash = excluded.secret_hash,
        name = excluded.name,
        paired_at = now(),
        expires_at = excluded.expires_at,
        revoked_at = null;

  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.remote_pair_device(text, uuid, text, text) from public, anon;
grant execute on function public.remote_pair_device(text, uuid, text, text) to authenticated;

create or replace function public.remote_send_command(
  p_device_id uuid,
  p_device_secret text,
  p_command_id uuid,
  p_machine_id uuid,
  p_session_id text,
  p_type text,
  p_payload jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ok boolean;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'not_authenticated');
  end if;

  select true into v_ok from public.remote_devices
  where id = p_device_id
    and user_id = auth.uid()
    and revoked_at is null
    and (expires_at is null or expires_at > now())
    and secret_hash = encode(digest(p_device_secret, 'sha256'), 'hex')
  limit 1;

  if not coalesce(v_ok, false) then
    return jsonb_build_object('ok', false, 'error', 'device_not_paired');
  end if;

  if not exists (select 1 from public.remote_machines where id = p_machine_id and user_id = auth.uid()) then
    return jsonb_build_object('ok', false, 'error', 'unknown_machine');
  end if;

  insert into public.remote_commands (id, user_id, machine_id, session_id, type, payload)
  values (p_command_id, auth.uid(), p_machine_id, p_session_id, p_type, p_payload);

  update public.remote_devices set last_used_at = now() where id = p_device_id;

  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.remote_send_command(uuid, text, uuid, uuid, text, text, jsonb) from public, anon;
grant execute on function public.remote_send_command(uuid, text, uuid, uuid, text, text, jsonb) to authenticated;