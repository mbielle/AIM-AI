-- PREPARED ONLY. Apply this single migration after review, never a global db push.
-- Authentication-session liveness is authoritative even before a JWT expires.
-- Existing pairing/ECDH keys/mirrors remain untouched. PIN hashes are removed only
-- in an explicitly requested, recently authorized account cutover.
begin;
-- Clean installation: preceding migrations define the reviewed function.

create schema if not exists aim_session_private;
revoke all on schema aim_session_private from public, anon, authenticated;
create table aim_session_private.function_backups(name text primary key, original_oid oid, definition text not null, original_name text not null, argument_types text not null, anon_execute boolean not null);
create table aim_session_private.policy_backups(table_name text primary key);
create table aim_session_private.pin_backups(user_id uuid primary key, row_data jsonb not null);
create table aim_session_private.constraint_backups(table_name text not null,name text not null,definition text not null,primary key(table_name,name));
-- Preserve the complete existing type predicate, adding only the two typed settings commands.
do $command_types$
declare predicate text;
begin
 select pg_get_constraintdef(oid) into predicate from pg_constraint
   where conrelid='public.remote_commands'::regclass and conname='remote_commands_type_check' and contype='c';
 if predicate is null or left(predicate,6)<>'CHECK ' then raise exception 'command_type_constraint_manual_review_required'; end if;
 insert into aim_session_private.constraint_backups values('remote_commands','remote_commands_type_check',predicate);
 alter table public.remote_commands drop constraint remote_commands_type_check;
 execute format('alter table public.remote_commands add constraint remote_commands_type_check check ((%s) or type in (''get_mac_settings'',''set_mac_settings''))',substring(predicate from 7));
end $command_types$;

create table public.aim_account_session_metadata(
  id uuid primary key, user_id uuid not null, device text not null, platform text not null,
  last_active_at timestamptz not null default now(), revoked_at timestamptz, local_stop_confirmed_at timestamptz);
create table public.aim_account_documents(
  user_id uuid not null, id uuid not null, kind text not null check(kind in ('chat','project','favorites','preferences','connectors')),
  payload text not null check(octet_length(payload)<=16000000), revision bigint not null check(revision>0),
  deleted boolean not null default false, updated_at timestamptz not null default now(), primary key(user_id,id));
create table public.aim_device_auth_accounts(user_id uuid primary key, version int not null check(version=2), legacy_protected boolean not null, migrated_at timestamptz not null default now());
create table public.aim_device_grants(
  token_hash text primary key, user_id uuid not null, device_id uuid not null, account_session_id uuid not null,
  expires_at timestamptz not null, revoked_at timestamptz);
create table public.aim_remote_task_owners(
  command_id uuid primary key, user_id uuid not null, machine_id uuid not null, actor_session_id uuid not null,
  host_session_id uuid, conversation_id text, created_at timestamptz not null default now(), stopped_at timestamptz);
create table public.aim_session_stop_requests(
  id uuid primary key default gen_random_uuid(), user_id uuid not null, account_session_id uuid not null,
  machine_id uuid not null, requested_at timestamptz not null default now(), confirmed_at timestamptz,
  unique(account_session_id,machine_id));
create index on public.aim_remote_task_owners(actor_session_id,machine_id);
create index on public.aim_remote_task_owners(host_session_id,machine_id);
create table public.aim_remote_host_sessions(machine_id uuid primary key, user_id uuid not null,
  account_session_id uuid not null, registered_at timestamptz not null default now());
-- Account deletion must also delete synchronized content and the rollback hash.
do $$ declare t text; begin
  foreach t in array array['aim_account_session_metadata','aim_account_documents','aim_device_auth_accounts','aim_device_grants','aim_remote_task_owners','aim_session_stop_requests','aim_remote_host_sessions'] loop
    execute format('alter table public.%I add foreign key(user_id) references auth.users(id) on delete cascade',t);
  end loop;
end $$;
alter table aim_session_private.pin_backups add foreign key(user_id) references auth.users(id) on delete cascade;

create function public.aim_session_is_live() returns boolean language sql stable security definer set search_path=public,auth as $$
  select auth.uid() is not null and exists(select 1 from auth.sessions s where s.id=nullif(auth.jwt()->>'session_id','')::uuid
    and s.user_id=auth.uid() and (s.not_after is null or s.not_after>now()))
    and not exists(select 1 from public.aim_account_session_metadata m where m.id=nullif(auth.jwt()->>'session_id','')::uuid and m.revoked_at is not null);
$$;
create function public.aim_require_live_session() returns uuid language plpgsql security definer set search_path=public,auth as $$
begin
  -- Lock admission against simultaneous logout. Logout waits for the admitted transaction,
  -- then records stop requests for every task committed by that transaction.
  perform 1 from auth.sessions s where s.id=nullif(auth.jwt()->>'session_id','')::uuid and s.user_id=auth.uid()
    and (s.not_after is null or s.not_after>now()) for share;
  if not found or not public.aim_session_is_live() then raise exception 'session_revoked' using errcode='42501'; end if;
  return (auth.jwt()->>'session_id')::uuid;
end $$;

-- Guard existing authenticated SECURITY DEFINER entry points too. A restrictive RLS
-- policy alone cannot protect a definer function. Keep original bodies, defaults,
-- signatures and grants; originals become inaccessible through PostgREST.
do $guard$
declare f record; args text; result text; call_args text; body text; backup_name text;
begin
  for f in select p.*, pg_get_function_arguments(p.oid) arguments, pg_get_function_result(p.oid) result_type,
    pg_get_function_identity_arguments(p.oid) identity_args, pg_get_functiondef(p.oid) definition
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.prokind='f' and p.prosecdef and p.prorettype not in ('trigger'::regtype,'event_trigger'::regtype) and p.proname not like 'aim_%'
      and has_function_privilege('authenticated',p.oid,'EXECUTE')
      and (position('auth.uid()' in pg_get_functiondef(p.oid))>0 or p.proname='remote_unlock_valide')
  loop
    if f.proargmodes is not null and exists(select 1 from unnest(f.proargmodes) mode where mode not in ('i','t')) then
      raise exception 'unsupported_definer_signature_%_manual_review_required',f.proname;
    end if;
    backup_name='original_'||f.oid::text;
    insert into aim_session_private.function_backups values(backup_name,f.oid,f.definition,f.proname,pg_get_function_identity_arguments(f.oid),has_function_privilege('anon',f.oid,'EXECUTE'));
    select string_agg(format('$%s',i),', ' order by i) into call_args from generate_series(1,f.pronargs) i;
    call_args=coalesce(call_args,'');
    execute format('alter function public.%I(%s) set schema aim_session_private',f.proname,f.identity_args);
    execute format('alter function aim_session_private.%I(%s) rename to %I',f.proname,f.identity_args,backup_name);
    execute format('revoke all on function aim_session_private.%I(%s) from public,anon,authenticated',backup_name,f.identity_args);
    body='begin if coalesce(auth.role(),'''')<>''service_role'' then perform public.aim_require_live_session(); end if; ';
    if f.proretset then body=body||format('return query select * from aim_session_private.%I(%s); ',backup_name,call_args);
    elsif f.result_type='void' then body=body||format('perform aim_session_private.%I(%s); return; ',backup_name,call_args);
    else body=body||format('return aim_session_private.%I(%s); ',backup_name,call_args); end if;
    body=body||'end';
    execute format('create function public.%I(%s) returns %s language plpgsql security definer set search_path=public,extensions as %L',f.proname,f.arguments,f.result_type,body);
    execute format('revoke all on function public.%I(%s) from public,anon,authenticated',f.proname,f.identity_args);
    -- Preserve existing anon grants, but the wrapper still requires a live session.
    if (select anon_execute from aim_session_private.function_backups where name=backup_name) then
      execute format('grant execute on function public.%I(%s) to anon',f.proname,f.identity_args);
    end if;
    -- Eligibility above establishes authenticated access.
    execute format('grant execute on function public.%I(%s) to authenticated,service_role',f.proname,f.identity_args);
  end loop;
end $guard$;

-- Existing user tables keep their owner/account predicates, plus session liveness.
-- No direct API access to the new security/control tables.
do $rls$
declare t record;
begin
  for t in select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relkind='r' and c.relrowsecurity and c.relname not like 'aim_%'
  loop
    execute format('create policy aim_live_account_session on public.%I as restrictive for all to authenticated using(public.aim_session_is_live()) with check(public.aim_session_is_live())',t.relname);
    insert into aim_session_private.policy_backups values(t.relname);
  end loop;
end $rls$;
-- Storage uses its own schema and must reject the same unexpired revoked JWT.
do $$ begin
  if to_regclass('storage.objects') is not null then
    execute 'create policy aim_live_account_session on storage.objects as restrictive for all to authenticated using(public.aim_session_is_live()) with check(public.aim_session_is_live())';
    insert into aim_session_private.policy_backups values('storage.objects');
  end if;
end $$;
do $$ declare t text; begin
  foreach t in array array['aim_account_session_metadata','aim_account_documents','aim_device_auth_accounts','aim_device_grants','aim_remote_task_owners','aim_session_stop_requests','aim_remote_host_sessions'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('revoke all on public.%I from public,anon,authenticated',t);
  end loop;
end $$;

create function public.aim_register_account_session(p_device text,p_platform text) returns void language plpgsql security definer set search_path=public,auth as $$
declare sid uuid=public.aim_require_live_session(); begin
  if length(p_device) not between 1 and 120 or length(p_platform) not between 1 and 80 then raise exception 'invalid_metadata'; end if;
  insert into aim_account_session_metadata(id,user_id,device,platform) values(sid,auth.uid(),p_device,p_platform)
    on conflict(id) do update set last_active_at=now(),device=excluded.device,platform=excluded.platform;
end $$;
create function public.aim_account_sessions() returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare sid uuid=public.aim_require_live_session(); result jsonb; begin
  select coalesce(jsonb_agg(x.row order by x.activity desc),'[]') into result from (
    select coalesce(m.last_active_at,s.refreshed_at::timestamptz,s.updated_at,s.created_at) activity,
      jsonb_build_object('id',coalesce(s.id,m.id),'device',coalesce(m.device,'Device not reported'),
        'platform',coalesce(m.platform,s.user_agent,'Platform not reported'),'last_active_at',coalesce(m.last_active_at,s.refreshed_at::timestamptz,s.updated_at,s.created_at),
        'is_current',coalesce(s.id,m.id)=sid,'revoked_at',m.revoked_at,
        'stop_state',case when m.revoked_at is null then null
           when m.local_stop_confirmed_at is null or exists(select 1 from aim_session_stop_requests r where r.account_session_id=m.id and r.confirmed_at is null) then 'requested' else 'confirmed' end) row
    from auth.sessions s full join aim_account_session_metadata m on m.id=s.id
    where coalesce(s.user_id,m.user_id)=auth.uid() and (s.id is not null or m.revoked_at>now()-interval '30 days')
  ) x; return result;
end $$;
create function public.aim_revoke_account_sessions(p_scope text,p_session_id uuid default null) returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare sid uuid=public.aim_require_live_session(); targets uuid[]; begin
  if p_scope not in ('session','others','all') or (p_scope='session' and p_session_id is null) then raise exception 'invalid_scope'; end if;
  perform 1 from auth.sessions s where s.user_id=auth.uid() and (p_scope='all' or p_scope='others' and s.id<>sid or p_scope='session' and s.id=p_session_id) for update;
  select coalesce(array_agg(s.id),'{}') into targets from auth.sessions s where s.user_id=auth.uid()
    and (p_scope='all' or p_scope='others' and s.id<>sid or p_scope='session' and s.id=p_session_id);
  if p_scope='session' and cardinality(targets)=0 then raise exception 'session_not_found' using errcode='42501'; end if;
  insert into aim_account_session_metadata(id,user_id,device,platform,last_active_at,revoked_at)
    select s.id,s.user_id,'Device not reported',coalesce(s.user_agent,'Platform not reported'),coalesce(s.updated_at,s.created_at),now()
    from auth.sessions s where s.id=any(targets)
    on conflict(id) do update set revoked_at=now(),local_stop_confirmed_at=null;
  insert into aim_session_stop_requests(user_id,account_session_id,machine_id)
    select distinct auth.uid(),target,o.machine_id from unnest(targets) target join aim_remote_task_owners o
      on o.actor_session_id=target or o.host_session_id=target where o.user_id=auth.uid() and o.stopped_at is null
    on conflict(account_session_id,machine_id) do update set requested_at=now(),confirmed_at=null;
  update remote_commands c set status='error',error='session_revoked',done_at=now()
    where c.status='pending' and exists(select 1 from aim_remote_task_owners o where o.command_id=c.id and o.user_id=auth.uid()
      and (o.actor_session_id=any(targets) or o.host_session_id=any(targets)));
  update aim_device_grants set revoked_at=now() where account_session_id=any(targets) and user_id=auth.uid();
  -- Revoke refresh credentials AND remove authoritative sessions. JWTs are blocked by live checks.
  update auth.refresh_tokens set revoked=true where session_id=any(targets) and user_id=auth.uid()::text;
  delete from auth.sessions where id=any(targets) and user_id=auth.uid();
  return jsonb_build_object('revoked_ids',targets,'stop_requested',cardinality(targets)>0, 'current_revoked',sid=any(targets));
end $$;

-- Stop-only acknowledgement accepts a revoked but not expired JWT. It can only
-- confirm local cleanup of its own session, never read data or grant access.
create function public.aim_ack_local_session_stop() returns void language plpgsql security definer set search_path=public,auth as $$
begin
  update aim_account_session_metadata set local_stop_confirmed_at=now()
    where id=nullif(auth.jwt()->>'session_id','')::uuid and user_id=auth.uid() and revoked_at is not null;
  if not found then raise exception 'revoked_session_not_found' using errcode='42501'; end if;
end $$;

create function public.aim_account_documents(p_account_id uuid) returns jsonb language plpgsql security definer set search_path=public as $$
begin perform aim_require_live_session(); if p_account_id is distinct from auth.uid() then raise exception 'account_changed' using errcode='42501'; end if; return coalesce((select jsonb_agg(jsonb_build_object('id',id,'kind',kind,'payload',payload,'revision',revision,'deleted',deleted) order by updated_at) from aim_account_documents where user_id=auth.uid()),'[]'); end $$;
create function public.aim_put_account_document(p_document jsonb,p_account_id uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare v public.aim_account_documents; expected bigint=(p_document->>'revision')::bigint; begin
  perform aim_require_live_session();
  if p_account_id is distinct from auth.uid() then raise exception 'account_changed' using errcode='42501'; end if;
  if expected<0 or (p_document->>'kind') not in ('chat','project','favorites','preferences','connectors') or octet_length(p_document->>'payload')>16000000 then raise exception 'invalid_document'; end if;
  -- Unique key and conditional upsert cover the absent-row race too.
  insert into aim_account_documents(user_id,id,kind,payload,revision,deleted)
    values(auth.uid(),(p_document->>'id')::uuid,p_document->>'kind',p_document->>'payload',1,coalesce((p_document->>'deleted')::boolean,false))
    on conflict(user_id,id) do update set payload=excluded.payload,revision=aim_account_documents.revision+1,deleted=excluded.deleted,updated_at=now()
      where aim_account_documents.revision=expected and aim_account_documents.kind=excluded.kind
    returning * into v;
  if not found or (v.revision=1 and expected<>0) then raise exception 'revision_conflict' using errcode='40001'; end if;
  return jsonb_build_object('id',v.id,'kind',v.kind,'payload',v.payload,'revision',v.revision,'deleted',v.deleted);
end $$;

create function public.aim_check_device(p_device_id uuid,p_device_secret text) returns void language plpgsql security definer set search_path=public,extensions as $$
begin
 perform aim_require_live_session();
 perform 1 from remote_devices where id=p_device_id and user_id=auth.uid() and revoked_at is null and (expires_at is null or expires_at>now())
   and secret_hash=encode(digest(p_device_secret,'sha256'),'hex') for share;
 if not found then raise exception 'device_not_paired' using errcode='42501'; end if;
end $$;
create function public.remote_device_authorization_state(p_device_id uuid,p_device_secret text) returns jsonb language plpgsql security definer set search_path=public as $$
begin perform aim_check_device(p_device_id,p_device_secret);
 return coalesce((select jsonb_build_object('version',version,'legacy_protected',legacy_protected) from aim_device_auth_accounts where user_id=auth.uid()),jsonb_build_object('version',1,'legacy_protected',false)); end $$;
create function public.remote_authorize_device(p_device_id uuid,p_device_secret text) returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare token text=encode(gen_random_bytes(32),'hex'); expiry timestamptz=now()+interval '20 minutes'; sid uuid; begin
  perform aim_check_device(p_device_id,p_device_secret); sid=aim_require_live_session();
  if not exists(select 1 from aim_device_auth_accounts where user_id=auth.uid() and version=2) then raise exception 'migration_required'; end if;
  delete from aim_device_grants where user_id=auth.uid() and device_id=p_device_id and (expires_at<=now() or account_session_id=sid);
  insert into aim_device_grants values(encode(digest(token,'sha256'),'hex'),auth.uid(),p_device_id,sid,expiry,null);
  return jsonb_build_object('token',token,'expiresAt',expiry,'method','device_v2');
end $$;
create function public.remote_migrate_device_authorization(p_device_id uuid,p_device_secret text,p_unlock_token text default null) returns jsonb language plpgsql security definer set search_path=public,extensions,auth as $$
declare protected boolean; sid uuid=aim_require_live_session(); begin
  perform aim_check_device(p_device_id,p_device_secret);
  -- Serialize account cutovers. A migration cannot weaken an existing protection state.
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,20261006));
  if exists(select 1 from aim_device_auth_accounts where user_id=auth.uid()) then return remote_device_authorization_state(p_device_id,p_device_secret); end if;
  if exists(select 1 from remote_unlock_pin where user_id=auth.uid())
     and not public.remote_unlock_valide(auth.uid(),p_device_id,p_unlock_token)
     and not exists(select 1 from auth.sessions where id=sid and user_id=auth.uid() and created_at>now()-interval '5 minutes') then
    raise exception 'fresh_sign_in_required' using errcode='42501';
  end if;
  select case when p.user_id is not null then cardinality(p.protected_modes)>0 else coalesce(f.enabled,true) end into protected
    from (select auth.uid() uid) u left join remote_security_policies p on p.user_id=u.uid left join remote_unlock_prefs f on f.user_id=u.uid;
  insert into aim_session_private.pin_backups select user_id,to_jsonb(remote_unlock_pin) from remote_unlock_pin where user_id=auth.uid()
    on conflict(user_id) do update set row_data=excluded.row_data;
  insert into aim_device_auth_accounts values(auth.uid(),2,coalesce(protected,true),now());
  delete from remote_unlock_sessions where user_id=auth.uid();
  delete from remote_unlock_pin where user_id=auth.uid();
  return remote_device_authorization_state(p_device_id,p_device_secret);
end $$;
create function public.remote_revoke_device_authorization(p_device_id uuid,p_device_secret text) returns void language plpgsql security definer set search_path=public as $$
begin perform aim_check_device(p_device_id,p_device_secret); update aim_device_grants set revoked_at=now() where user_id=auth.uid() and device_id=p_device_id and account_session_id=(auth.jwt()->>'session_id')::uuid; end $$;

-- Rebase this body's legacy delegation against the private saved definition.
-- No PIN/passkey token is accepted after the account cutover.
create or replace function public.remote_unlock_valide(p_user uuid,p_device_id uuid,p_token text) returns boolean language plpgsql security definer set search_path=public,extensions as $$
declare f text; result boolean; begin
  if exists(select 1 from aim_device_auth_accounts where user_id=p_user) then
    return p_user=auth.uid() and aim_session_is_live() and exists(select 1 from aim_device_grants g join remote_devices d on d.id=g.device_id
      where g.user_id=p_user and g.device_id=p_device_id and g.account_session_id=(auth.jwt()->>'session_id')::uuid
      and g.expires_at>now() and g.revoked_at is null and g.token_hash=encode(digest(coalesce(p_token,''),'sha256'),'hex')
      and d.user_id=p_user and d.revoked_at is null and (d.expires_at is null or d.expires_at>now()));
  end if;
  select name into f from aim_session_private.function_backups where original_name='remote_unlock_valide';
  if f is null then raise exception 'legacy_unlock_definition_missing'; end if;
  execute format('select aim_session_private.%I($1,$2,$3)',f) into result using p_user,p_device_id,p_token; return result;
end $$;

-- Special wrapper also records the admitted caller and rejects old clients after cutover.
create or replace function public.remote_send_command(p_device_id uuid,p_device_secret text,p_command_id uuid,p_machine_id uuid,p_session_id text,p_type text,p_payload jsonb,p_unlock_token text default null,p_mode text default null)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare f text; result jsonb; sid uuid=aim_require_live_session(); begin
  perform aim_check_device(p_device_id,p_device_secret);
  if exists(select 1 from aim_device_auth_accounts where user_id=auth.uid()) and p_type<>'request_keys' and not remote_unlock_valide(auth.uid(),p_device_id,p_unlock_token) then
    return jsonb_build_object('ok',false,'error','device_authorization_required');
  end if;
  if exists(select 1 from aim_device_auth_accounts where user_id=auth.uid())
     and not exists(select 1 from aim_remote_host_sessions h join auth.sessions s on s.id=h.account_session_id
       where h.machine_id=p_machine_id and h.user_id=auth.uid() and s.user_id=auth.uid() and (s.not_after is null or s.not_after>now())) then
    return jsonb_build_object('ok',false,'error','mac_update_required');
  end if;
  select name into f from aim_session_private.function_backups where original_name='remote_send_command';
  if f is null then raise exception 'admission_definition_missing'; end if;
  -- New typed settings require owned machine + device grant; they never run shell strings.
  if p_type in ('get_mac_settings','set_mac_settings') then
    if not remote_unlock_valide(auth.uid(),p_device_id,p_unlock_token) then return jsonb_build_object('ok',false,'error','unlock_required'); end if;
    if not exists(select 1 from remote_machines where id=p_machine_id and user_id=auth.uid()) then return jsonb_build_object('ok',false,'error','machine_not_owned'); end if;
    insert into remote_commands(id,user_id,machine_id,session_id,type,payload,status) values(p_command_id,auth.uid(),p_machine_id,null,p_type,p_payload,'pending')
      on conflict(id) do nothing;
    if not exists(select 1 from remote_commands where id=p_command_id and user_id=auth.uid() and machine_id=p_machine_id and type=p_type and payload=p_payload) then raise exception 'idempotence_conflict'; end if;
    result=jsonb_build_object('ok',true);
  else
    execute format('select aim_session_private.%I($1,$2,$3,$4,$5,$6,$7,$8,$9)',f) into result using p_device_id,p_device_secret,p_command_id,p_machine_id,p_session_id,p_type,p_payload,p_unlock_token,p_mode;
  end if;
  if result->>'ok'='true' and exists(select 1 from remote_commands where id=p_command_id and user_id=auth.uid()) then
    insert into aim_remote_task_owners(command_id,user_id,machine_id,actor_session_id,host_session_id,conversation_id)
      values(p_command_id,auth.uid(),p_machine_id,sid,
        (select account_session_id from aim_remote_host_sessions where machine_id=p_machine_id and user_id=auth.uid()),
        case when p_type='create_session' then p_command_id::text else nullif(p_session_id,'') end) on conflict(command_id) do nothing;
    if not exists(select 1 from aim_remote_task_owners where command_id=p_command_id and user_id=auth.uid() and actor_session_id=sid) then raise exception 'idempotence_owner_conflict'; end if;
  end if;
  return result;
end $$;

-- Machine-secret authentication for stop-only RPCs permits a revoked host to finish
-- stopping its tasks, without granting it access to normal account resources.
create function public.aim_check_machine(p_machine_id uuid,p_secret text) returns void language plpgsql security definer set search_path=public,extensions as $$
begin
  if auth.uid() is null or not exists(select 1 from remote_machines where id=p_machine_id and user_id=auth.uid() and secret_hash=encode(digest(p_secret,'sha256'),'hex')) then raise exception 'machine_not_owned' using errcode='42501'; end if;
end $$;
create function public.aim_remote_command_authorized(p_machine_id uuid,p_secret text,p_command_id uuid,p_conversation_id text default null) returns boolean language plpgsql security definer set search_path=public,auth as $$
declare sid uuid=aim_require_live_session(); owner public.aim_remote_task_owners; begin
  perform aim_check_machine(p_machine_id,p_secret);
  select * into owner from aim_remote_task_owners where command_id=p_command_id and user_id=auth.uid() and machine_id=p_machine_id for update;
  -- Pre-migration historical commands have no trustworthy initiating session. Fail closed.
  if not found or not exists(select 1 from auth.sessions where id=owner.actor_session_id and user_id=auth.uid() and (not_after is null or not_after>now())) then return false; end if;
  if owner.stopped_at is not null or exists(select 1 from aim_session_stop_requests where machine_id=p_machine_id and confirmed_at is null and account_session_id in (owner.actor_session_id,sid)) then return false; end if;
  update aim_remote_task_owners set host_session_id=sid,conversation_id=coalesce(nullif(p_conversation_id,''),conversation_id) where command_id=p_command_id;
  return true;
end $$;
create function public.aim_register_remote_host(p_machine_id uuid,p_secret text) returns void language plpgsql security definer set search_path=public as $$
declare sid uuid=aim_require_live_session(); begin
  perform aim_check_machine(p_machine_id,p_secret);
  insert into aim_remote_host_sessions values(p_machine_id,auth.uid(),sid,now())
    on conflict(machine_id) do update set account_session_id=sid,registered_at=now()
      where aim_remote_host_sessions.user_id=auth.uid();
end $$;
-- Old hosts cannot receive a v2 account's commands through table polling. The
-- initiating phone may still observe its own status; all existing owner policies apply.
create function public.aim_command_visible(p_machine_id uuid,p_command_id uuid) returns boolean language sql stable security definer set search_path=public,auth as $$
 select not exists(select 1 from aim_device_auth_accounts where user_id=auth.uid())
   or exists(select 1 from aim_remote_host_sessions where machine_id=p_machine_id and user_id=auth.uid() and account_session_id=(auth.jwt()->>'session_id')::uuid)
   or exists(select 1 from aim_remote_task_owners where command_id=p_command_id and user_id=auth.uid() and actor_session_id=(auth.jwt()->>'session_id')::uuid);
$$;
create policy aim_v2_host_commands on public.remote_commands as restrictive for select to authenticated using(public.aim_command_visible(machine_id,id));
create function public.aim_remote_stop_requests(p_machine_id uuid,p_secret text) returns jsonb language plpgsql security definer set search_path=public as $$
begin
  perform aim_check_machine(p_machine_id,p_secret);
  return coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'command_ids',(select coalesce(jsonb_agg(command_id),'[]') from aim_remote_task_owners o where o.machine_id=r.machine_id and o.user_id=r.user_id and r.account_session_id in (o.actor_session_id,o.host_session_id)),
    'conversation_ids',(select coalesce(jsonb_agg(distinct conversation_id) filter(where conversation_id is not null),'[]') from aim_remote_task_owners o where o.machine_id=r.machine_id and o.user_id=r.user_id and r.account_session_id in (o.actor_session_id,o.host_session_id))))
    from aim_session_stop_requests r where r.user_id=auth.uid() and r.machine_id=p_machine_id and r.confirmed_at is null),'[]');
end $$;
create function public.aim_ack_remote_stop(p_machine_id uuid,p_secret text,p_request_id uuid) returns void language plpgsql security definer set search_path=public as $$
declare r public.aim_session_stop_requests; begin
 perform aim_check_machine(p_machine_id,p_secret);
 select * into r from aim_session_stop_requests where id=p_request_id and machine_id=p_machine_id and user_id=auth.uid() for update;
 if not found then raise exception 'stop_request_not_found'; end if;
 update aim_remote_task_owners set stopped_at=now() where machine_id=r.machine_id and user_id=r.user_id and r.account_session_id in (actor_session_id,host_session_id);
 update aim_session_stop_requests set confirmed_at=now() where id=r.id;
end $$;

-- New RPCs are authenticated only; implementation helpers have no direct grants.
do $$ declare f record; begin
 for f in select p.oid::regprocedure sig,p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and (p.proname like 'aim_%' or p.proname in ('remote_device_authorization_state','remote_authorize_device','remote_migrate_device_authorization','remote_revoke_device_authorization')) loop
   execute format('revoke all on function %s from public,anon,authenticated',f.sig);
   if f.proname not in ('aim_check_device','aim_check_machine','aim_require_live_session') then execute format('grant execute on function %s to authenticated,service_role',f.sig); end if;
 end loop;
end $$;
notify pgrst,'reload schema';
commit;
