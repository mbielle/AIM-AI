-- Mode remote — v2 des RPC machine. Deux corrections :
--
-- ① remote_create_pairing_code devient AUTO-RÉPARANTE : si le secret machine
--    n'est pas encore posé (1er démarrage, enregistrement pas encore passé),
--    elle le pose elle-même (même TOFU que l'enregistrement) au lieu de
--    refuser « machine_not_registered ». C'est ce refus, avalé en silence par
--    l'UI, qui rendait le bouton « Générer un code » muet.
-- ② L'upsert de remote_register_machine pouvait réassigner user_id d'une ligne
--    machine appartenant à un AUTRE utilisateur (si son secret n'était pas posé
--    et son UUID connu). Les deux fonctions scopent désormais l'update au
--    propriétaire (WHERE user_id = auth.uid()) et revérifient l'état final.

create or replace function public.remote_register_machine(
  p_machine_id uuid,
  p_name text,
  p_platform text,
  p_app_version text,
  p_secret text
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

  insert into public.remote_machines (id, user_id, name, platform, app_version, last_seen_at, secret_hash)
  values (p_machine_id, auth.uid(), coalesce(nullif(p_name, ''), 'Mon ordinateur'), p_platform, p_app_version, now(), v_hash)
  on conflict (id) do update
    set name = coalesce(nullif(excluded.name, ''), public.remote_machines.name),
        platform = excluded.platform,
        app_version = excluded.app_version,
        last_seen_at = now(),
        secret_hash = coalesce(public.remote_machines.secret_hash, excluded.secret_hash)
    where public.remote_machines.user_id = auth.uid(); -- jamais la machine d'un autre

  select secret_hash into v_row_hash from public.remote_machines
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

create or replace function public.remote_create_pairing_code(
  p_machine_id uuid,
  p_secret text
) returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_hash text;
  v_row_hash text;
  v_alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_code text := '';
  v_expires timestamptz;
  i int;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'not_authenticated');
  end if;
  if p_secret is null or length(p_secret) < 32 then
    return jsonb_build_object('ok', false, 'error', 'weak_secret');
  end if;
  v_hash := encode(digest(p_secret, 'sha256'), 'hex');

  -- Auto-réparation : pose le secret si absent (même TOFU que l'enregistrement),
  -- scopé au propriétaire. Ne touche jamais la machine d'un autre utilisateur.
  insert into public.remote_machines (id, user_id, last_seen_at, secret_hash)
  values (p_machine_id, auth.uid(), now(), v_hash)
  on conflict (id) do update
    set last_seen_at = now(),
        secret_hash = coalesce(public.remote_machines.secret_hash, excluded.secret_hash)
    where public.remote_machines.user_id = auth.uid();

  select secret_hash into v_row_hash from public.remote_machines
  where id = p_machine_id and user_id = auth.uid();

  if v_row_hash is null then
    return jsonb_build_object('ok', false, 'error', 'machine_conflict');
  end if;
  if v_row_hash <> v_hash then
    return jsonb_build_object('ok', false, 'error', 'machine_secret_mismatch');
  end if;

  -- 6 caractères ; alphabet de 32 → 256 % 32 = 0 donc pas de biais modulo.
  for i in 1..6 loop
    v_code := v_code || substr(v_alphabet, 1 + (get_byte(gen_random_bytes(1), 0) % length(v_alphabet)), 1);
  end loop;
  v_expires := now() + interval '5 minutes';

  insert into public.remote_pairing_codes (user_id, machine_id, code_hash, expires_at)
  values (auth.uid(), p_machine_id, encode(digest(v_code, 'sha256'), 'hex'), v_expires);

  return jsonb_build_object('ok', true, 'code', v_code, 'expires_at', v_expires);
end
$function$;

-- Resserrage : ces fonctions ne doivent pas être exécutables par anon (le
-- garde auth.uid() refuse déjà, ceinture et bretelles).
revoke execute on function public.remote_register_machine(uuid, text, text, text, text) from anon;
revoke execute on function public.remote_create_pairing_code(uuid, text) from anon;