-- Verrou de Code et Agent — étape 1 (additive, sans effet sur l'existant).
-- Décision du 2026-09-17 : l'appairage seul ne suffit plus pour piloter l'ordinateur.
-- Il faut un déverrouillage récent, par clé d'accès (WebAuthn : Face ID, Touch ID,
-- Windows Hello) ou par code PIN de secours, redemandé à chaque ouverture de Code/Agent.
-- L'obligation côté serveur (remote_send_command) est posée à l'étape 2, une fois le
-- site publié : d'ici là, ces objets existent sans rien bloquer.

-- Clés d'accès enregistrées (une par appareil ; la clé privée ne quitte jamais l'appareil).
create table if not exists public.remote_unlock_credentials (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  credential_id text not null unique,
  public_key text not null,
  counter bigint not null default 0,
  label text,
  created_at timestamptz not null default now(),
  last_used_at timestamptz
);
create index if not exists remote_unlock_credentials_user on public.remote_unlock_credentials (user_id);
alter table public.remote_unlock_credentials enable row level security;

-- L'utilisateur peut voir et retirer SES clés ; seul le serveur (service role) en écrit.
drop policy if exists remote_unlock_credentials_select_own on public.remote_unlock_credentials;
create policy remote_unlock_credentials_select_own on public.remote_unlock_credentials
  for select using (user_id = auth.uid());
drop policy if exists remote_unlock_credentials_delete_own on public.remote_unlock_credentials;
create policy remote_unlock_credentials_delete_own on public.remote_unlock_credentials
  for delete using (user_id = auth.uid());

-- Code PIN de secours : empreinte seulement, avec compteur d'échecs et blocage temporaire.
-- Aucune politique : la table n'est lisible que par le serveur.
create table if not exists public.remote_unlock_pin (
  user_id uuid primary key references auth.users(id) on delete cascade,
  pin_hash text not null,
  failed_attempts integer not null default 0,
  locked_until timestamptz,
  updated_at timestamptz not null default now()
);
alter table public.remote_unlock_pin enable row level security;

-- Déverrouillages en cours : jeton opaque (empreinte seule), lié à l'appareil appairé.
create table if not exists public.remote_unlock_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  token_hash text not null,
  method text not null check (method in ('passkey', 'pin')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);
create index if not exists remote_unlock_sessions_token on public.remote_unlock_sessions (token_hash);
create index if not exists remote_unlock_sessions_user on public.remote_unlock_sessions (user_id, device_id);
alter table public.remote_unlock_sessions enable row level security;

-- Défis WebAuthn (5 minutes) : un défi ne sert qu'une fois.
create table if not exists public.remote_webauthn_challenges (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  challenge text not null,
  kind text not null check (kind in ('register', 'auth')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);
create index if not exists remote_webauthn_challenges_user on public.remote_webauthn_challenges (user_id, kind);
alter table public.remote_webauthn_challenges enable row level security;

-- État du verrou pour l'appareil appairé courant (l'écran de verrou en a besoin).
create or replace function public.remote_unlock_state(p_device_id uuid, p_device_secret text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare
  v_ok boolean;
  v_pin public.remote_unlock_pin;
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

  select * into v_pin from public.remote_unlock_pin where user_id = auth.uid();

  return jsonb_build_object(
    'ok', true,
    'passkeys', (select count(*) from public.remote_unlock_credentials where user_id = auth.uid()),
    'pin', v_pin.user_id is not null,
    'locked_until', v_pin.locked_until
  );
end
$function$;
revoke all on function public.remote_unlock_state(uuid, text) from public;
grant execute on function public.remote_unlock_state(uuid, text) to authenticated;

-- Déverrouillage valide pour cet appareil ? (utilisé par remote_send_command à l'étape 2)
create or replace function public.remote_unlock_valide(p_user uuid, p_device_id uuid, p_token text)
returns boolean
language sql
security definer
set search_path to 'public', 'extensions'
as $function$
  select exists (
    select 1 from public.remote_unlock_sessions
    where user_id = p_user
      and device_id = p_device_id
      and token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex')
      and expires_at > now()
  );
$function$;
revoke all on function public.remote_unlock_valide(uuid, uuid, text) from public;

-- Oubli du PIN et perte de la clé d'accès : réappairer l'appareil depuis l'ordinateur
-- (le code d'appairage exige un accès physique) puis réinitialiser, dans les 10 minutes.
create or replace function public.remote_unlock_reset(p_device_id uuid, p_device_secret text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare
  v_paired_at timestamptz;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'not_authenticated');
  end if;

  select paired_at into v_paired_at from public.remote_devices
  where id = p_device_id
    and user_id = auth.uid()
    and revoked_at is null
    and (expires_at is null or expires_at > now())
    and secret_hash = encode(digest(p_device_secret, 'sha256'), 'hex')
  limit 1;

  if v_paired_at is null then
    return jsonb_build_object('ok', false, 'error', 'device_not_paired');
  end if;

  if v_paired_at < now() - interval '10 minutes' then
    return jsonb_build_object('ok', false, 'error', 'pairing_too_old');
  end if;

  delete from public.remote_unlock_pin where user_id = auth.uid();
  delete from public.remote_unlock_credentials where user_id = auth.uid();
  delete from public.remote_unlock_sessions where user_id = auth.uid();

  return jsonb_build_object('ok', true);
end
$function$;
revoke all on function public.remote_unlock_reset(uuid, text) from public;
grant execute on function public.remote_unlock_reset(uuid, text) to authenticated;

-- Ménage : jetons et défis périmés.
create or replace function public.remote_unlock_purge()
returns void
language sql
security definer
set search_path to 'public'
as $function$
  delete from public.remote_unlock_sessions where expires_at < now() - interval '1 day';
  delete from public.remote_webauthn_challenges where expires_at < now() - interval '1 hour';
$function$;
revoke all on function public.remote_unlock_purge() from public;

-- PIN : haché par pgcrypto (bcrypt). Réservé au serveur (service role) : aucun `grant`.
create or replace function public.remote_unlock_set_pin(p_user uuid, p_pin text)
returns void
language sql
security definer
set search_path to 'public', 'extensions'
as $function$
  insert into public.remote_unlock_pin (user_id, pin_hash, failed_attempts, locked_until, updated_at)
  values (p_user, crypt(p_pin, gen_salt('bf', 10)), 0, null, now())
  on conflict (user_id) do update
    set pin_hash = excluded.pin_hash, failed_attempts = 0, locked_until = null, updated_at = now();
$function$;
revoke all on function public.remote_unlock_set_pin(uuid, text) from public;

-- Vérification du PIN : 5 essais, puis blocage de 15 minutes. Jamais de détail sur l'erreur.
create or replace function public.remote_unlock_check_pin(p_user uuid, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare
  v_pin public.remote_unlock_pin;
  v_bon boolean;
  v_essais integer;
  v_blocage timestamptz;
begin
  select * into v_pin from public.remote_unlock_pin where user_id = p_user for update;
  if v_pin.user_id is null then
    return jsonb_build_object('ok', false, 'error', 'no_pin');
  end if;
  if v_pin.locked_until is not null and v_pin.locked_until > now() then
    return jsonb_build_object('ok', false, 'error', 'locked', 'locked_until', v_pin.locked_until);
  end if;

  v_bon := v_pin.pin_hash = crypt(p_pin, v_pin.pin_hash);
  if v_bon then
    update public.remote_unlock_pin set failed_attempts = 0, locked_until = null where user_id = p_user;
    return jsonb_build_object('ok', true);
  end if;

  update public.remote_unlock_pin
    set failed_attempts = v_pin.failed_attempts + 1,
        locked_until = case when v_pin.failed_attempts + 1 >= 5 then now() + interval '15 minutes' else null end
    where user_id = p_user
    returning failed_attempts, locked_until into v_essais, v_blocage;

  return jsonb_build_object('ok', false, 'error', 'wrong_pin', 'attempts', v_essais, 'locked_until', v_blocage);
end
$function$;
revoke all on function public.remote_unlock_check_pin(uuid, text) from public;

-- Obligation de déverrouillage : portée par un drapeau, donc activable et réversible
-- sans migration (étape 2 = passer ce drapeau à `true` une fois le site publié).
insert into public.remote_config (key, value)
values ('remote_unlock_required', 'false'::jsonb)
on conflict (key) do nothing;

-- `remote_send_command` accepte désormais un jeton de déverrouillage. Tant que le drapeau
-- est à `false`, le comportement est exactement celui d'avant (un client qui n'envoie pas
-- le jeton passe : le paramètre a une valeur par défaut).
drop function if exists public.remote_send_command(uuid, text, uuid, uuid, text, text, jsonb);

create or replace function public.remote_send_command(
  p_device_id uuid,
  p_device_secret text,
  p_command_id uuid,
  p_machine_id uuid,
  p_session_id text,
  p_type text,
  p_payload jsonb,
  p_unlock_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare
  v_ok boolean;
  v_exige boolean;
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

  select coalesce((value)::text = 'true', false) into v_exige
  from public.remote_config where key = 'remote_unlock_required';

  if coalesce(v_exige, false) and not public.remote_unlock_valide(auth.uid(), p_device_id, p_unlock_token) then
    return jsonb_build_object('ok', false, 'error', 'unlock_required');
  end if;

  if not exists (select 1 from public.remote_machines where id = p_machine_id and user_id = auth.uid()) then
    return jsonb_build_object('ok', false, 'error', 'unknown_machine');
  end if;

  insert into public.remote_commands (id, user_id, machine_id, session_id, type, payload)
  values (p_command_id, auth.uid(), p_machine_id, p_session_id, p_type, p_payload);

  update public.remote_devices set last_used_at = now() where id = p_device_id;

  return jsonb_build_object('ok', true);
end
$function$;

revoke all on function public.remote_send_command(uuid, text, uuid, uuid, text, text, jsonb, text) from public;
grant execute on function public.remote_send_command(uuid, text, uuid, uuid, text, text, jsonb, text) to authenticated, service_role;
