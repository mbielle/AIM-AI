-- PREPARED ONLY: no cron is installed and no email is sent by applying this migration.
begin;
create schema aim_release_private;
revoke all on schema aim_release_private from public,anon,authenticated;
create table aim_release_private.error_events (
 id bigint generated always as identity primary key,
 component text not null check(component in ('push','postgres','api')),
 code text not null check(code in ('request_failed','delivery_failed','database_failed','timeout')),
 created_at timestamptz not null default now()
);
create index on aim_release_private.error_events(created_at);
create table aim_release_private.incidents (
 key text primary key check(key in ('postgres_api','push','postgres_errors','api_errors')),
 active boolean not null default false,
 notified_active boolean not null default false,
 generation bigint not null default 0,
 changed_at timestamptz not null default now(),
 lease uuid, lease_until timestamptz
);
revoke all on all tables in schema aim_release_private from public,anon,authenticated;

create function public.aim_monitor_record_error(p_component text,p_code text) returns void
language plpgsql security definer set search_path=pg_catalog as $$
begin
 if auth.role() is distinct from 'service_role' then raise exception 'server_only' using errcode='42501'; end if;
 insert into aim_release_private.error_events(component,code) values(p_component,p_code);
end $$;

create function public.aim_monitor_snapshot() returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare result jsonb; failed bigint=0; backlog bigint=0; logged_postgres bigint=0; logged_api bigint=0;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'server_only' using errcode='42501'; end if;
 -- Never return push/account/event IDs or raw Postgres errors. Queue schema is optional until push migration lands.
 if to_regclass('public.aim_push_deliveries') is not null then
   execute 'select count(*) from public.aim_push_deliveries where state=''failed'' and updated_at>now()-interval ''15 minutes''' into failed;
   execute 'select count(*) from public.aim_push_deliveries where state in (''pending'',''sending'') and updated_at<now()-interval ''10 minutes''' into backlog;
 end if;
 -- Existing application error telemetry is aggregated in-place, never copied into emails.
 -- This covers reported errors only, not arbitrary PostgreSQL logs or a total database outage.
 if to_regclass('public.analytics_events') is not null then
   execute 'select count(*) filter(where event_data::text ~* ''(SQLSTATE|Postgres|PostgREST|40001|40P01|23505)''),count(*) filter(where event_data::text ~* ''(api_error|api_failed|HTTP.?5[0-9][0-9]|provider_unavailable)'') from public.analytics_events where event_category=''error'' and created_at>now()-interval ''15 minutes''' into logged_postgres,logged_api;
 end if;
 select jsonb_build_object('server_time',now(),
   'push_errors',count(*) filter(where component='push'),'postgres_errors',logged_postgres+count(*) filter(where component='postgres'),
   'api_errors',logged_api+count(*) filter(where component='api'),'push_failed',failed,'push_backlog',backlog)
 into result from aim_release_private.error_events where created_at>now()-interval '15 minutes';
 return result;
end $$;

create function public.aim_monitor_claim(p_key text,p_active boolean) returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$
declare incident aim_release_private.incidents; token uuid;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'server_only' using errcode='42501'; end if;
 if p_active is null then raise exception 'invalid_observation'; end if;
 insert into aim_release_private.incidents(key) values(p_key) on conflict do nothing;
 select * into incident from aim_release_private.incidents where key=p_key for update;
 if incident.active is distinct from p_active then
   update aim_release_private.incidents set active=p_active,generation=generation+1,changed_at=now(),lease=null,lease_until=null
   where key=p_key returning * into incident;
 end if;
 if incident.notified_active=incident.active or incident.lease_until>now() then return null; end if;
 token=gen_random_uuid();
 update aim_release_private.incidents set lease=token,lease_until=now()+interval '2 minutes' where key=p_key;
 return jsonb_build_object('key',p_key,'active',incident.active,'generation',incident.generation,'lease',token);
end $$;

create function public.aim_monitor_finish(p_key text,p_lease uuid,p_sent boolean) returns void
language plpgsql security definer set search_path=pg_catalog as $$
begin
 if auth.role() is distinct from 'service_role' then raise exception 'server_only' using errcode='42501'; end if;
 update aim_release_private.incidents set notified_active=case when p_sent then active else notified_active end,lease=null,lease_until=null
 where key=p_key and lease=p_lease and lease_until>now();
end $$;

-- SQL dispatch uses a distinct worker secret in Vault, never service-role in a cron command.
create function aim_release_private.dispatch_tick() returns void
language plpgsql security definer set search_path=pg_catalog as $$
declare endpoint text; secret text;
begin
 if to_regclass('vault.decrypted_secrets') is null or to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then raise exception 'monitor_scheduler_not_configured'; end if;
 execute 'select decrypted_secret from vault.decrypted_secrets where name=''aim_release_monitor_url''' into endpoint;
 execute 'select decrypted_secret from vault.decrypted_secrets where name=''aim_release_monitor_secret''' into secret;
 if endpoint is null or endpoint !~ '^https://[a-z0-9]+\.supabase\.co/functions/v1/aim-release-monitor$' or secret is null or secret !~ '^[a-fA-F0-9]{64}$' then raise exception 'monitor_scheduler_not_configured'; end if;
 perform net.http_post(url=>endpoint,headers=>jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||secret),body=>'{}'::jsonb,timeout_milliseconds=>55000);
end $$;
revoke all on function public.aim_monitor_record_error(text,text),public.aim_monitor_snapshot(),public.aim_monitor_claim(text,boolean),public.aim_monitor_finish(text,uuid,boolean) from public,anon,authenticated;
grant execute on function public.aim_monitor_record_error(text,text),public.aim_monitor_snapshot(),public.aim_monitor_claim(text,boolean),public.aim_monitor_finish(text,uuid,boolean) to service_role;
revoke all on function aim_release_private.dispatch_tick() from public,anon,authenticated,service_role;
commit;
