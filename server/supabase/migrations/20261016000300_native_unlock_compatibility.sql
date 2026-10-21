begin;
-- The original legacy validator was private, so the session wrapper never archived it.
-- Preserve its hash/expiry contract directly while retaining the v2 session-bound grant check.
create or replace function public.remote_unlock_valide(p_user uuid, p_device_id uuid, p_token text)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_user = auth.uid() and public.aim_session_is_live()
    and exists (
      select 1 from public.remote_devices d
      where d.id = p_device_id and d.user_id = p_user and d.revoked_at is null
        and (d.expires_at is null or d.expires_at > now())
    )
    and case when exists (select 1 from public.aim_device_auth_accounts where user_id = p_user) then
      exists (
        select 1 from public.aim_device_grants g
        where g.user_id = p_user and g.device_id = p_device_id
          and g.account_session_id = (auth.jwt()->>'session_id')::uuid
          and g.expires_at > now() and g.revoked_at is null
          and g.token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex')
      )
    else
      exists (
        select 1 from public.remote_unlock_sessions s
        where s.user_id = p_user and s.device_id = p_device_id and s.expires_at > now()
          and s.token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex')
      )
    end;
$$;
revoke all on function public.remote_unlock_valide(uuid, uuid, text)
  from public, anon, authenticated;

-- Native legacy PIN compatibility only. Current clients migrate to device-v2 grants.
-- Keep bcrypt and its authoritative attempt/lock rules in the existing SQL helpers.
create or replace function public.aim_native_pin_unlock(
  p_action text,
  p_device_id uuid,
  p_device_secret text,
  p_pin text default null,
  p_unlock_token text default null
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  sid uuid = public.aim_require_live_session();
  result jsonb;
  token text;
  expiry timestamptz;
begin
  perform public.aim_check_device(p_device_id, p_device_secret);
  if p_action = 'lock' then
    delete from public.remote_unlock_sessions
      where user_id = auth.uid() and device_id = p_device_id
        and token_hash = encode(extensions.digest(coalesce(p_unlock_token, ''), 'sha256'), 'hex');
    update public.aim_device_grants set revoked_at = now()
      where user_id = auth.uid() and device_id = p_device_id and account_session_id = sid;
    return jsonb_build_object('ok', true);
  end if;
  if p_action not in ('pin-set', 'pin-verify') then
    return jsonb_build_object('ok', false, 'error', 'action_inconnue');
  end if;

  -- Share the account cutover lock: no PIN can be created concurrently after v2 migration.
  -- This also serializes initial PIN creation and its authoritative attempt counter.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(auth.uid()::text, 20261006));
  if exists (select 1 from public.aim_device_auth_accounts where user_id = auth.uid() and version = 2) then
    return jsonb_build_object('ok', false, 'error', 'legacy_security_retired');
  end if;
  if p_pin is null or p_pin !~ '^[0-9]{6}$' then
    return jsonb_build_object('ok', false, 'error', 'pin_invalide');
  end if;
  if p_action = 'pin-set' then
    if exists (select 1 from public.remote_unlock_pin where user_id = auth.uid())
      and not public.remote_unlock_valide(auth.uid(), p_device_id, p_unlock_token) then
      return jsonb_build_object('ok', false, 'error', 'deverrouillage_requis');
    end if;
    perform public.remote_unlock_set_pin(auth.uid(), p_pin);
  else
    result = public.remote_unlock_check_pin(auth.uid(), p_pin);
    if not coalesce((result->>'ok')::boolean, false) then
      return result;
    end if;
  end if;

  token = encode(extensions.gen_random_bytes(32), 'hex');
  expiry = now() + interval '12 hours';
  delete from public.remote_unlock_sessions
    where user_id = auth.uid() and expires_at < now() - interval '1 day';
  insert into public.remote_unlock_sessions(user_id, device_id, token_hash, method, expires_at)
    values(auth.uid(), p_device_id, encode(extensions.digest(token, 'sha256'), 'hex'), 'pin', expiry);
  return jsonb_build_object('ok', true, 'unlock', jsonb_build_object(
    'token', token, 'expiresAt', expiry, 'method', 'pin'
  ));
end;
$$;
revoke all on function public.aim_native_pin_unlock(text, uuid, text, text, text) from public, anon;
grant execute on function public.aim_native_pin_unlock(text, uuid, text, text, text) to authenticated;
commit;
