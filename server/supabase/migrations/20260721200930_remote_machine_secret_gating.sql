-- Durcissement sécurité mode remote (Phase 1, additif) : donner à l'ORDINATEUR
-- un secret de machine, pour que la CRÉATION d'un code d'appairage exige la
-- preuve d'être la vraie machine (pas juste le compte). Sans ça, un compte volé
-- peut fabriquer un code (ou insérer un appareil) et contourner tout l'appairage.
--
-- Rien n'est verrouillé ici (Phase 3) : on ajoute seulement la colonne + 2 RPC.
-- L'app 1.0.88 continue de fonctionner (écritures directes encore ouvertes).

alter table public.remote_machines
  add column if not exists secret_hash text;

-- Enregistrement/heartbeat de la machine, prouvé par son secret. Le secret est
-- posé UNE fois (TOFU) puis exigé identique : un attaquant ne peut pas l'écraser.
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
  v_existing text;
  v_hash text;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'not_authenticated');
  end if;
  if p_secret is null or length(p_secret) < 32 then
    return jsonb_build_object('ok', false, 'error', 'weak_secret');
  end if;
  v_hash := encode(digest(p_secret, 'sha256'), 'hex');

  select secret_hash into v_existing from public.remote_machines where id = p_machine_id;

  if v_existing is not null and v_existing <> v_hash then
    -- Secret déjà posé et différent : refus (on ne peut pas détourner la machine).
    return jsonb_build_object('ok', false, 'error', 'machine_secret_mismatch');
  end if;

  insert into public.remote_machines (id, user_id, name, platform, app_version, last_seen_at, secret_hash)
  values (p_machine_id, auth.uid(), coalesce(nullif(p_name, ''), 'Mon ordinateur'), p_platform, p_app_version, now(), v_hash)
  on conflict (id) do update
    set user_id = auth.uid(),
        name = coalesce(nullif(excluded.name, ''), public.remote_machines.name),
        platform = excluded.platform,
        app_version = excluded.app_version,
        last_seen_at = now(),
        secret_hash = coalesce(public.remote_machines.secret_hash, excluded.secret_hash); -- pose si null, sinon garde

  return jsonb_build_object('ok', true);
end
$function$;

-- Génère un code d'appairage CÔTÉ SERVEUR, seulement si l'appelant prouve le
-- secret de la machine. Un compte volé (sans le secret) ne peut pas en créer.
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
  v_alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; -- sans 0/O/1/I
  v_code text := '';
  v_expires timestamptz;
  i int;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'not_authenticated');
  end if;

  select secret_hash into v_hash from public.remote_machines
  where id = p_machine_id and user_id = auth.uid();

  if v_hash is null then
    return jsonb_build_object('ok', false, 'error', 'machine_not_registered');
  end if;
  if v_hash <> encode(digest(p_secret, 'sha256'), 'hex') then
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

-- Exécutables par les utilisateurs connectés uniquement (jamais anon).
revoke all on function public.remote_register_machine(uuid, text, text, text, text) from public;
grant execute on function public.remote_register_machine(uuid, text, text, text, text) to authenticated;
revoke all on function public.remote_create_pairing_code(uuid, text) from public;
grant execute on function public.remote_create_pairing_code(uuid, text) to authenticated;