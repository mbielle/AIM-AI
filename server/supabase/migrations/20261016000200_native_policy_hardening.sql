-- Fresh installations: native access and tenant-boundary hardening.
begin;
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
commit;
