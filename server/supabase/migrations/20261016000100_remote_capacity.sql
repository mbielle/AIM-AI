-- Technical resource bounds, independent from feature/payment access.
-- Stop/cancel and permission replies are not rate-limited by this admission layer.
begin;
create schema aim_remote_capacity;
revoke all on schema aim_remote_capacity from public, anon, authenticated;
create table aim_remote_capacity.settings(
  singleton boolean primary key default true check(singleton),
  commands_per_minute integer not null default 120 check(commands_per_minute between 1 and 10000),
  max_pending integer not null default 500 check(max_pending between 1 and 100000)
);
insert into aim_remote_capacity.settings default values;
create table aim_remote_capacity.windows(
  user_id uuid primary key references auth.users(id) on delete cascade,
  started_at timestamptz not null,
  commands integer not null
);
alter function public.remote_send_command(uuid, text, uuid, uuid, text, text, jsonb, text, text)
  set schema aim_remote_capacity;
alter function aim_remote_capacity.remote_send_command(uuid, text, uuid, uuid, text, text, jsonb, text, text)
  rename to authorized_send_command;
revoke all on function aim_remote_capacity.authorized_send_command(uuid, text, uuid, uuid, text, text, jsonb, text, text)
  from public, anon, authenticated;

create function public.remote_send_command(
  p_device_id uuid, p_device_secret text, p_command_id uuid, p_machine_id uuid,
  p_session_id text, p_type text, p_payload jsonb,
  p_unlock_token text default null, p_mode text default null
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  settings aim_remote_capacity.settings;
  amount integer;
begin
  perform public.aim_require_live_session();
  perform public.aim_check_device(p_device_id, p_device_secret);
  -- Only explicit stop/cancel/permission replies bypass resource admission.
  if p_type not in (
    'stop_generation', 'stop_command', 'stop_preview', 'goal_pause', 'goal_cancel',
    'approval_response', 'goal_approval_response', 'goal_question_response'
  ) then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(auth.uid()::text, 20261016));
    -- Recheck after locking: overlapping retries of one command are admitted once.
    if not exists (select 1 from public.remote_commands where id = p_command_id and user_id = auth.uid()) then
      select * into strict settings from aim_remote_capacity.settings where singleton;
      if (select count(*) from public.remote_commands
          where user_id = auth.uid() and status in ('pending', 'ack')) >= settings.max_pending then
        return jsonb_build_object('ok', false, 'error', 'queue_capacity_reached');
      end if;
      insert into aim_remote_capacity.windows values(auth.uid(), date_trunc('minute', now()), 1)
        on conflict(user_id) do update set
          started_at = excluded.started_at,
          commands = case when aim_remote_capacity.windows.started_at = excluded.started_at
            then aim_remote_capacity.windows.commands + 1 else 1 end
        returning commands into amount;
      if amount > settings.commands_per_minute then
        return jsonb_build_object('ok', false, 'error', 'rate_limited');
      end if;
    end if;
  end if;
  return aim_remote_capacity.authorized_send_command(
    p_device_id, p_device_secret, p_command_id, p_machine_id, p_session_id,
    p_type, p_payload, p_unlock_token, p_mode
  );
end;
$$;
revoke all on function public.remote_send_command(uuid, text, uuid, uuid, text, text, jsonb, text, text)
  from public, anon;
grant execute on function public.remote_send_command(uuid, text, uuid, uuid, text, text, jsonb, text, text)
  to authenticated, service_role;

create function public.aim_service_capacity()
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'server_only' using errcode = '42501';
  end if;
  return (
    select jsonb_build_object(
      'remote_pending', count(*) filter(where status in ('pending', 'ack')),
      'oldest_pending_seconds', coalesce(extract(epoch from now() - min(created_at) filter(where status = 'pending')), 0),
      'remote_rows', count(*)
    ) from public.remote_commands
  );
end;
$$;
revoke all on function public.aim_service_capacity() from public, anon, authenticated;
grant execute on function public.aim_service_capacity() to service_role;
commit;
