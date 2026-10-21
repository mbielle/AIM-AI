-- Protocole Remote v2 — R3a : timeline ordonnée et capacités de la machine.
-- Les deux colonnes contiennent soit l'ancien clair (avant activation R2), soit
-- une chaîne e1.* AES-GCM stockée dans jsonb. Elles restent donc additives.

alter table public.remote_messages
  add column if not exists timeline jsonb;

alter table public.remote_machines
  add column if not exists capabilities jsonb;

-- Nouvelle surcharge : l'ancienne signature à cinq paramètres reste en place
-- pour les versions desktop déjà publiées. Les appels PostgREST étant nommés,
-- la présence de p_capabilities sélectionne sans ambiguïté cette version R3a.
create or replace function public.remote_register_machine(
  p_machine_id uuid,
  p_name text,
  p_platform text,
  p_app_version text,
  p_secret text,
  p_capabilities jsonb
) returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_hash text;
  v_row_hash text;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'not_authenticated');
  end if;
  if p_secret is null or length(p_secret) < 32 then
    return jsonb_build_object('ok', false, 'error', 'weak_secret');
  end if;
  v_hash := encode(digest(p_secret, 'sha256'), 'hex');

  insert into public.remote_machines (
    id, user_id, name, platform, app_version, capabilities, last_seen_at, secret_hash
  ) values (
    p_machine_id, auth.uid(), coalesce(nullif(p_name, ''), 'Mon ordinateur'),
    p_platform, p_app_version, p_capabilities, now(), v_hash
  )
  on conflict (id) do update
    set name = coalesce(nullif(excluded.name, ''), public.remote_machines.name),
        platform = excluded.platform,
        app_version = excluded.app_version,
        capabilities = coalesce(excluded.capabilities, public.remote_machines.capabilities),
        last_seen_at = now(),
        secret_hash = coalesce(public.remote_machines.secret_hash, excluded.secret_hash)
    where public.remote_machines.user_id = auth.uid();

  select secret_hash into v_row_hash
  from public.remote_machines
  where id = p_machine_id and user_id = auth.uid();

  if v_row_hash is null then
    return jsonb_build_object('ok', false, 'error', 'machine_conflict');
  end if;
  if v_row_hash <> v_hash then
    return jsonb_build_object('ok', false, 'error', 'machine_secret_mismatch');
  end if;
  return jsonb_build_object('ok', true);
end
$function$;

revoke all on function public.remote_register_machine(uuid, text, text, text, text, jsonb) from public;
grant execute on function public.remote_register_machine(uuid, text, text, text, text, jsonb) to authenticated;
