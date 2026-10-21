-- Protocole remote v2 — R2 : chiffrement de bout en bout.
-- Additif : les clients qui ne connaissent pas ces colonnes continuent de fonctionner.

-- 1. Clé publique de l'appareil (ECDH P-256, brute non compressée, 65 octets en base64).
alter table public.remote_devices add column if not exists public_key text;

-- 2. Version courante de la clé de miroir de chaque ordinateur (le téléphone sait laquelle attendre).
alter table public.remote_machines add column if not exists key_version integer;

-- 3. Les enveloppes : la clé de miroir chiffrée POUR un appareil. Illisible sans sa clé privée.
create table if not exists public.remote_device_keys (
  device_id   uuid not null references public.remote_devices(id) on delete cascade,
  machine_id  uuid not null references public.remote_machines(id) on delete cascade,
  key_version integer not null check (key_version > 0),
  user_id     uuid not null references auth.users(id) on delete cascade,
  envelope    jsonb not null,
  created_at  timestamptz not null default now(),
  primary key (device_id, machine_id, key_version)
);
alter table public.remote_device_keys enable row level security;
drop policy if exists remote_device_keys_select_own on public.remote_device_keys;
create policy remote_device_keys_select_own on public.remote_device_keys
  for select using (user_id = auth.uid());
-- Aucune écriture directe : seules les fonctions ci-dessous écrivent.
revoke insert, update, delete on public.remote_device_keys from anon, authenticated;
grant select on public.remote_device_keys to authenticated;

-- Contrôle de forme d'une clé publique P-256 brute.
create or replace function public.remote_cle_publique_valide(p text)
returns boolean language plpgsql immutable set search_path to 'public', 'extensions' as $$
declare b bytea;
begin
  if p is null or length(p) <> 88 then return false; end if;
  b := decode(p, 'base64');
  return length(b) = 65 and get_byte(b, 0) = 4;
exception when others then
  return false;
end $$;

-- 4. Appairage : accepte désormais la clé publique (facultative pour les anciens clients).
--    Un ré-appairage REMPLACE la clé (null si l'ancien client n'en envoie pas).
drop function if exists public.remote_pair_device(text, uuid, text, text);
create or replace function public.remote_pair_device(
  p_code text, p_device_id uuid, p_device_secret text, p_device_name text default 'Appareil'::text,
  p_public_key text default null
)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $function$
declare
  v_row public.remote_pairing_codes%rowtype;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'not_authenticated');
  end if;
  if p_device_secret is null or length(p_device_secret) < 32 then
    return jsonb_build_object('ok', false, 'error', 'weak_secret');
  end if;
  if p_public_key is not null and not public.remote_cle_publique_valide(p_public_key) then
    return jsonb_build_object('ok', false, 'error', 'invalid_public_key');
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

  insert into public.remote_devices (id, user_id, name, secret_hash, expires_at, public_key)
  values (
    p_device_id, auth.uid(), coalesce(nullif(p_device_name, ''), 'Appareil'),
    encode(digest(p_device_secret, 'sha256'), 'hex'),
    now() + interval '90 days',
    p_public_key
  )
  on conflict (id) do update
    set secret_hash = excluded.secret_hash,
        name = excluded.name,
        paired_at = now(),
        expires_at = excluded.expires_at,
        revoked_at = null,
        public_key = excluded.public_key
    where public.remote_devices.user_id = auth.uid();

  -- Nouvelle clé publique ⇒ les anciennes enveloppes de cet appareil ne s'ouvrent plus : on les retire.
  delete from public.remote_device_keys where device_id = p_device_id;

  -- Plafond : ne garder que les 5 appareils actifs les plus récents.
  update public.remote_devices
  set revoked_at = now()
  where user_id = auth.uid()
    and revoked_at is null
    and id not in (
      select id from public.remote_devices
      where user_id = auth.uid() and revoked_at is null
      order by paired_at desc
      limit 5
    );

  return jsonb_build_object('ok', true);
end
$function$;

-- 5. Un appareil déjà appairé (sans clé) peut poser SA clé UNE fois, prouvée par son secret.
--    La changer ensuite exige un nouvel appairage physique (code affiché sur l'ordinateur).
create or replace function public.remote_set_device_key(p_device_id uuid, p_device_secret text, p_public_key text)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $function$
declare
  v_cle text;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'not_authenticated');
  end if;
  if not public.remote_cle_publique_valide(p_public_key) then
    return jsonb_build_object('ok', false, 'error', 'invalid_public_key');
  end if;
  select public_key into v_cle from public.remote_devices
  where id = p_device_id
    and user_id = auth.uid()
    and revoked_at is null
    and (expires_at is null or expires_at > now())
    and secret_hash = encode(digest(p_device_secret, 'sha256'), 'hex');
  if not found then
    return jsonb_build_object('ok', false, 'error', 'device_not_paired');
  end if;
  if v_cle is not null then
    if v_cle = p_public_key then return jsonb_build_object('ok', true); end if;
    return jsonb_build_object('ok', false, 'error', 'key_already_set');
  end if;
  update public.remote_devices set public_key = p_public_key where id = p_device_id;
  return jsonb_build_object('ok', true);
end
$function$;

-- 6. L'ordinateur dépose les enveloppes, prouvé par SON secret de machine.
--    p_envelopes = [{ "device_id": uuid, "envelope": {...} }, ...]
create or replace function public.remote_put_device_keys(
  p_machine_id uuid, p_secret text, p_key_version integer, p_envelopes jsonb
)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $function$
declare
  v_e jsonb;
  v_n integer := 0;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'not_authenticated');
  end if;
  if p_key_version is null or p_key_version < 1 then
    return jsonb_build_object('ok', false, 'error', 'invalid_version');
  end if;
  if not exists (
    select 1 from public.remote_machines
    where id = p_machine_id and user_id = auth.uid()
      and secret_hash = encode(digest(coalesce(p_secret, ''), 'sha256'), 'hex')
  ) then
    return jsonb_build_object('ok', false, 'error', 'machine_secret_mismatch');
  end if;
  if jsonb_typeof(coalesce(p_envelopes, '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_envelopes, '[]'::jsonb)) > 10 then
    return jsonb_build_object('ok', false, 'error', 'invalid_envelopes');
  end if;

  for v_e in select * from jsonb_array_elements(coalesce(p_envelopes, '[]'::jsonb)) loop
    -- Seulement pour un appareil ACTIF de ce compte, qui a une clé publique.
    if exists (
      select 1 from public.remote_devices d
      where d.id = (v_e->>'device_id')::uuid and d.user_id = auth.uid()
        and d.revoked_at is null and (d.expires_at is null or d.expires_at > now())
        and d.public_key is not null
    ) and jsonb_typeof(v_e->'envelope') = 'object' and (v_e->'envelope'->>'kv')::int = p_key_version then
      insert into public.remote_device_keys (device_id, machine_id, key_version, user_id, envelope)
      values ((v_e->>'device_id')::uuid, p_machine_id, p_key_version, auth.uid(), v_e->'envelope')
      on conflict (device_id, machine_id, key_version) do update set envelope = excluded.envelope, created_at = now();
      v_n := v_n + 1;
    end if;
  end loop;

  update public.remote_machines set key_version = p_key_version where id = p_machine_id;
  -- On garde la version précédente le temps que le miroir soit re-chiffré, pas plus.
  delete from public.remote_device_keys
  where machine_id = p_machine_id and key_version < p_key_version - 1;
  -- Un appareil révoqué ne reçoit plus rien, et perd ce qu'il avait.
  delete from public.remote_device_keys k
  using public.remote_devices d
  where k.machine_id = p_machine_id and d.id = k.device_id and d.revoked_at is not null;

  return jsonb_build_object('ok', true, 'stored', v_n);
end
$function$;

revoke all on function public.remote_set_device_key(uuid, text, text) from public, anon;
revoke all on function public.remote_put_device_keys(uuid, text, integer, jsonb) from public, anon;
revoke all on function public.remote_pair_device(text, uuid, text, text, text) from public, anon;
grant execute on function public.remote_set_device_key(uuid, text, text) to authenticated;
grant execute on function public.remote_put_device_keys(uuid, text, integer, jsonb) to authenticated;
grant execute on function public.remote_pair_device(text, uuid, text, text, text) to authenticated;

-- 7. La clé publique d'un appareil ne se modifie QUE par les fonctions ci-dessus
--    (la règle d'update existante autorise la révocation : elle ne doit pas servir à substituer une clé).
create or replace function public.remote_devices_garde_cle()
returns trigger language plpgsql set search_path to 'public' as $$
begin
  if new.public_key is distinct from old.public_key and current_user in ('authenticated', 'anon') then
    raise exception 'public_key_read_only';
  end if;
  return new;
end $$;
drop trigger if exists remote_devices_garde_cle on public.remote_devices;
create trigger remote_devices_garde_cle before update on public.remote_devices
  for each row execute function public.remote_devices_garde_cle();

-- 8. Nouvelle commande sans charge : « ordinateur, dépose-moi ma clé maintenant ».
alter table public.remote_commands drop constraint if exists remote_commands_type_check;
alter table public.remote_commands add constraint remote_commands_type_check check (type = any (array[
  'user_message', 'approval_response', 'set_model', 'set_approval_mode', 'request_diff', 'start_preview',
  'stop_preview', 'run_command', 'stop_command', 'list_folders', 'create_folder', 'create_session',
  'stop_generation', 'resume_turn', 'request_keys'
]::text[]));

-- Realtime : le téléphone voit arriver sa clé sans attendre.
do $$ begin
  alter publication supabase_realtime add table public.remote_device_keys;
exception when duplicate_object then null; when undefined_object then null;
end $$;
