-- CORRECTIF — mode remote : les RPC d'appairage et d'envoi de commande forçaient
-- `search_path TO 'public'`, or `digest()` (pgcrypto) vit dans le schéma
-- `extensions` sur Supabase → introuvable → exception → l'appairage échouait
-- toujours (message générique côté site). On ajoute `extensions` au search_path
-- des deux fonctions. Corps inchangé par ailleurs. Réversible (retirer 'extensions').

CREATE OR REPLACE FUNCTION public.remote_pair_device(p_code text, p_device_id uuid, p_device_secret text, p_device_name text DEFAULT 'Appareil'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.remote_send_command(p_device_id uuid, p_device_secret text, p_command_id uuid, p_machine_id uuid, p_session_id text, p_type text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$;