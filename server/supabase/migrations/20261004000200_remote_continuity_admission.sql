-- Prepared from the deployed AIM-AI function inspected READ ONLY on 2026-10-04.
-- Preserve authentication, pairing/revocation, expiry, secret and unlock checks.
-- Fail on drift so a later security fix cannot be overwritten accidentally.
-- Clean installation: preceding migrations define the reviewed function.


CREATE OR REPLACE FUNCTION public.remote_send_command(p_device_id uuid, p_device_secret text, p_command_id uuid, p_machine_id uuid, p_session_id text, p_type text, p_payload jsonb, p_unlock_token text DEFAULT NULL::text, p_mode text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_ok boolean;
  v_exige boolean;
  v_mode text;
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

  if p_type = 'create_session' then
    v_mode := lower(coalesce(p_mode, ''));
    if v_mode not in ('chat', 'code', 'agent') then
      return jsonb_build_object('ok', false, 'error', 'invalid_mode');
    end if;
  elsif p_session_id is not null then
    select mode into v_mode from public.remote_sessions
    where id = p_session_id and user_id = auth.uid()
    limit 1;
  end if;

  if coalesce(v_exige, false)
    and public.remote_unlock_actif(auth.uid())
    and p_type <> 'request_keys'
    and coalesce(v_mode, '') <> 'chat'
    and not public.remote_unlock_valide(auth.uid(), p_device_id, p_unlock_token) then
    return jsonb_build_object('ok', false, 'error', 'unlock_required');
  end if;

  if not exists (select 1 from public.remote_machines where id = p_machine_id and user_id = auth.uid()) then
    return jsonb_build_object('ok', false, 'error', 'unknown_machine');
  end if;

  -- Stable encrypted envelope was persisted on the client before the first RPC.
  -- Duplicate IDs are accepted only for the exact same authenticated command.
  insert into public.remote_commands (id, user_id, machine_id, session_id, type, payload)
  values (p_command_id, auth.uid(), p_machine_id, p_session_id, p_type, p_payload)
  on conflict (id) do nothing;
  if not exists (
    select 1 from public.remote_commands
    where id = p_command_id and user_id = auth.uid() and machine_id = p_machine_id
      and session_id is not distinct from p_session_id and type = p_type and payload = p_payload
  ) then
    return jsonb_build_object('ok', false, 'error', 'command_conflict');
  end if;

  update public.remote_devices set last_used_at = now() where id = p_device_id;
  return jsonb_build_object('ok', true);
end
$function$
;
