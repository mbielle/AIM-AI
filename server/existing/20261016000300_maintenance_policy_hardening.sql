-- EXISTING installations only: apply on a restored staging copy after free_access.
-- Additive maintenance API/policy hardening; no financial, account or pairing rows are purged.
-- Requires the reviewed session, account-media and Remote baseline; missing objects fail closed.
begin;
-- Account-scoped export/deletion support; no service-role exposed to clients.
create or replace function public.aim_account_storage_paths()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  result jsonb;
begin
  perform public.aim_require_live_session();
  select coalesce(jsonb_agg(jsonb_build_object('bucket', bucket_id, 'name', name)), '[]'::jsonb)
    into result
    from storage.objects
    where (storage.foldername(name))[1] = auth.uid()::text;
  return result;
end;
$$;
revoke all on function public.aim_account_storage_paths() from public, anon;
grant execute on function public.aim_account_storage_paths() to authenticated;

-- Explicit grants make a fresh installation independent of dashboard defaults.
grant usage on schema public to authenticated;
grant select, insert, update, delete on
  public.profiles, public.projects, public.conversations, public.messages,
  public.project_files, public.user_preferences, public.user_memory_documents,
  public.generated_images, public.generated_videos, public.user_connectors
  to authenticated;

-- Deliberate public maintenance entrypoints; implementation helper stays private.
create or replace function public.aim_maintenance_session()
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  perform public.aim_require_live_session();
  return true;
end;
$$;

create or replace function public.aim_export_account_documents()
returns setof public.aim_account_documents
language plpgsql security definer set search_path = '' as $$
begin
  perform public.aim_require_live_session();
  return query select * from public.aim_account_documents where user_id = auth.uid() order by id;
end;
$$;
revoke all on function public.aim_maintenance_session(), public.aim_export_account_documents()
  from public, anon;
grant execute on function public.aim_maintenance_session(), public.aim_export_account_documents()
  to authenticated;

alter policy account_media_read on public.account_media_assets to authenticated
using(account_id=(select auth.uid()) and (select public.aim_session_is_live()));

alter policy aim_media_object_read on storage.objects to authenticated using(
  bucket_id='account-media' and (storage.foldername(name))[1]=(select auth.uid())::text
  and (select public.aim_session_is_live())
  and (storage.allow_any_operation(array['object.delete','object.delete_many'])
    or not exists(select 1 from public.account_media_assets a where a.account_id=auth.uid()
      and a.id::text=(storage.foldername(name))[2] and a.deleted_at is not null)));
alter policy aim_media_object_insert on storage.objects to authenticated with check(
  bucket_id='account-media' and (storage.foldername(name))[1]=(select auth.uid())::text
  and array_length(storage.foldername(name),1)=2 and storage.filename(name)='result'
  and (storage.foldername(name))[2] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  and (select public.aim_session_is_live())
  and not exists(select 1 from public.account_media_assets a where a.account_id=auth.uid()
      and a.id::text=(storage.foldername(name))[2] and a.deleted_at is not null));
alter policy aim_media_object_update on storage.objects to authenticated using(
  bucket_id='account-media' and (storage.foldername(name))[1]=(select auth.uid())::text
  and (select public.aim_session_is_live()))
with check(bucket_id='account-media' and (storage.foldername(name))[1]=(select auth.uid())::text
  and array_length(storage.foldername(name),1)=2 and storage.filename(name)='result'
  and (storage.foldername(name))[2] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  and (select public.aim_session_is_live())
  and not exists(select 1 from public.account_media_assets a where a.account_id=auth.uid()
      and a.id::text=(storage.foldername(name))[2] and a.deleted_at is not null));
alter policy aim_media_object_delete on storage.objects to authenticated using(
  bucket_id='account-media' and (storage.foldername(name))[1]=(select auth.uid())::text
  and (select public.aim_session_is_live()));

-- Explicit application privileges: never rely on a platform ALL/TRUNCATE default.
revoke all on
  public.profiles, public.projects, public.conversations, public.messages,
  public.project_files, public.user_preferences, public.user_memory_documents,
  public.generated_images, public.generated_videos, public.user_connectors
  from public, anon, authenticated;
grant select, insert, update, delete on
  public.profiles, public.projects, public.conversations, public.messages,
  public.project_files, public.user_preferences, public.user_memory_documents,
  public.generated_images, public.generated_videos, public.user_connectors
  to authenticated;
revoke all on
  public.remote_machines, public.remote_devices, public.remote_commands,
  public.remote_sessions, public.remote_messages, public.remote_transfers,
  public.remote_session_attachments, public.remote_device_keys
  from public, anon, authenticated;
grant usage on schema public, storage to authenticated;
grant select on public.remote_machines, public.remote_devices, public.remote_commands, public.remote_device_keys
  to authenticated;
grant update(revoked_at) on public.remote_devices to authenticated;
grant select, insert, update, delete on public.remote_sessions, public.remote_messages, public.remote_transfers
  to authenticated;
grant select, insert on public.remote_session_attachments to authenticated;
-- Storage is a platform table; preserve other bucket policies but never grant TRUNCATE.
revoke truncate, references, trigger on storage.objects from anon, authenticated;
grant select, insert, update, delete on storage.objects to authenticated;

-- Preserve tenant boundaries on every future child write, including definer RPCs.
-- Existing records are neither rewritten nor deleted by this migration.
create or replace function public.aim_native_remote_parent_owner()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_table_name = 'remote_sessions' then
    if not exists (select 1 from public.remote_machines where id = new.machine_id and user_id = new.user_id) then
      raise exception 'machine_not_owned' using errcode = '42501';
    end if;
  else
    if not exists (select 1 from public.remote_sessions where id = new.session_id and user_id = new.user_id) then
      raise exception 'session_not_owned' using errcode = '42501';
    end if;
    if tg_table_name in ('remote_transfers', 'remote_session_attachments') then
      if not exists (select 1 from public.remote_sessions
          where id = new.session_id and user_id = new.user_id and machine_id = new.machine_id) then
        raise exception 'session_machine_mismatch' using errcode = '42501';
      end if;
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.aim_native_remote_parent_owner() from public, anon, authenticated;
drop trigger if exists aim_native_parent_owner on public.remote_sessions;
create trigger aim_native_parent_owner before insert or update on public.remote_sessions
  for each row execute function public.aim_native_remote_parent_owner();
drop trigger if exists aim_native_parent_owner on public.remote_messages;
create trigger aim_native_parent_owner before insert or update on public.remote_messages
  for each row execute function public.aim_native_remote_parent_owner();
drop trigger if exists aim_native_parent_owner on public.remote_transfers;
create trigger aim_native_parent_owner before insert or update on public.remote_transfers
  for each row execute function public.aim_native_remote_parent_owner();
drop trigger if exists aim_native_parent_owner on public.remote_session_attachments;
create trigger aim_native_parent_owner before insert or update on public.remote_session_attachments
  for each row execute function public.aim_native_remote_parent_owner();

-- Replace the public pairing entry point, retaining the existing wire signature.
-- A foreign device ID must never delete its envelopes or consume the caller's code.
create or replace function public.remote_pair_device(
  p_code text, p_device_id uuid, p_device_secret text,
  p_device_name text default 'Appareil', p_public_key text default null
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  code_row public.remote_pairing_codes;
  paired uuid;
begin
  perform public.aim_require_live_session();
  if p_device_secret is null or length(p_device_secret) < 32 then
    return jsonb_build_object('ok', false, 'error', 'weak_secret');
  end if;
  if p_public_key is not null and not public.remote_cle_publique_valide(p_public_key) then
    return jsonb_build_object('ok', false, 'error', 'invalid_public_key');
  end if;
  select * into code_row from public.remote_pairing_codes
    where user_id = auth.uid() and consumed_at is null and expires_at > now()
      and code_hash = encode(extensions.digest(p_code, 'sha256'), 'hex')
    order by created_at desc limit 1 for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'invalid_or_expired_code');
  end if;
  insert into public.remote_devices(id, user_id, name, secret_hash, expires_at, public_key)
    values(p_device_id, auth.uid(), coalesce(nullif(p_device_name, ''), 'Appareil'),
      encode(extensions.digest(p_device_secret, 'sha256'), 'hex'), now() + interval '90 days', p_public_key)
    on conflict(id) do update set
      secret_hash = excluded.secret_hash, name = excluded.name, paired_at = now(),
      expires_at = excluded.expires_at, revoked_at = null, public_key = excluded.public_key
      where public.remote_devices.user_id = auth.uid()
    returning id into paired;
  if paired is null then
    raise exception 'device_conflict' using errcode = '42501';
  end if;
  update public.remote_pairing_codes set consumed_at = now() where id = code_row.id;
  delete from public.remote_device_keys where device_id = p_device_id and user_id = auth.uid();
  update public.remote_devices set revoked_at = now()
    where user_id = auth.uid() and revoked_at is null and id not in (
      select id from public.remote_devices where user_id = auth.uid() and revoked_at is null
        order by paired_at desc, id limit 5
    );
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.remote_pair_device(text, uuid, text, text, text) from public, anon;
grant execute on function public.remote_pair_device(text, uuid, text, text, text) to authenticated;

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
