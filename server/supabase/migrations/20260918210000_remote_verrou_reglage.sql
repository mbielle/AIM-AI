-- Verrou Remote : réglage par compte (décision de Mathieu, 2026-09-18).
--
-- ⚠️ Annule « redemandé à chaque ouverture de Code/Agent » (décision du 17/09) :
--   * le déverrouillage vaut pour toute l'app jusqu'à sa fermeture, ou 15 min en arrière-plan
--     (côté client : le jeton ne vit qu'en mémoire) ;
--   * le Chat n'est jamais verrouillé (il ne pilote pas l'ordinateur) ;
--   * l'utilisateur peut désactiver le verrou (Paramètres › Confidentialité). Le COUPER exige
--     un déverrouillage valide : un téléphone volé ne peut pas s'en affranchir.
--
-- Additif et sans effet tant que `remote_unlock_required` vaut false (étape 2 non activée) :
-- seules les réponses de `remote_unlock_state` gagnent le champ `enabled`.

create table if not exists public.remote_unlock_prefs (
  user_id uuid primary key references auth.users(id) on delete cascade,
  enabled boolean not null default true,
  updated_at timestamptz not null default now()
);
alter table public.remote_unlock_prefs enable row level security;
-- Aucune politique : lue et écrite uniquement par les fonctions ci-dessous.

-- Le verrou est-il actif pour ce compte ? (absent = actif)
create or replace function public.remote_unlock_actif(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce((select enabled from public.remote_unlock_prefs where user_id = p_user), true);
$function$;
revoke all on function public.remote_unlock_actif(uuid) from public;

-- État du verrou pour l'appareil appairé courant : + `enabled`.
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
    'locked_until', v_pin.locked_until,
    'enabled', public.remote_unlock_actif(auth.uid())
  );
end
$function$;
revoke all on function public.remote_unlock_state(uuid, text) from public;
grant execute on function public.remote_unlock_state(uuid, text) to authenticated;

-- Activer / désactiver le verrou. Désactiver exige un déverrouillage valide dès qu'un verrou
-- (PIN ou clé d'accès) existe.
create or replace function public.remote_unlock_set_enabled(
  p_device_id uuid,
  p_device_secret text,
  p_enabled boolean,
  p_unlock_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare
  v_ok boolean;
  v_configure boolean;
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

  if not coalesce(p_enabled, true) then
    v_configure := exists (select 1 from public.remote_unlock_pin where user_id = auth.uid())
      or exists (select 1 from public.remote_unlock_credentials where user_id = auth.uid());
    if v_configure and not public.remote_unlock_valide(auth.uid(), p_device_id, p_unlock_token) then
      return jsonb_build_object('ok', false, 'error', 'unlock_required');
    end if;
  end if;

  insert into public.remote_unlock_prefs (user_id, enabled, updated_at)
  values (auth.uid(), coalesce(p_enabled, true), now())
  on conflict (user_id) do update set enabled = excluded.enabled, updated_at = now();

  return jsonb_build_object('ok', true, 'enabled', coalesce(p_enabled, true));
end
$function$;
revoke all on function public.remote_unlock_set_enabled(uuid, text, boolean, text) from public;
grant execute on function public.remote_unlock_set_enabled(uuid, text, boolean, text) to authenticated;

-- Étape 2 (drapeau `remote_unlock_required`) : le jeton n'est exigé que si le verrou est actif
-- pour ce compte, et jamais pour une conversation Chat existante.
-- ⚠️ Reste à traiter AVANT l'étape 2 : `create_session` d'un Chat n'a pas encore de session (et
-- sa charge est chiffrée) — il faudra un mode en clair que l'ordinateur vérifie.
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

  if coalesce(v_exige, false)
    and public.remote_unlock_actif(auth.uid())
    and not exists (
      select 1 from public.remote_sessions
      where id = p_session_id and user_id = auth.uid() and mode = 'chat'
    )
    and not public.remote_unlock_valide(auth.uid(), p_device_id, p_unlock_token) then
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
