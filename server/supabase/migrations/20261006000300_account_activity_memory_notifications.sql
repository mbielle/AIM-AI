-- PREPARED FOR REVIEW ONLY. Apply only this migration after review; never replay 001/002.
-- Existing data and authoritative session/device checks are preserved.
begin;
create table aim_session_private.settings_v3_backup(key text primary key,definition text not null);
revoke all on aim_session_private.settings_v3_backup from public,anon,authenticated;
insert into aim_session_private.settings_v3_backup values('aim_put_account_document',pg_get_functiondef('public.aim_put_account_document(jsonb,uuid)'::regprocedure));
insert into aim_session_private.settings_v3_backup select 'document_kind_constraint',pg_get_constraintdef(oid) from pg_constraint where conrelid='public.aim_account_documents'::regclass and conname='aim_account_documents_kind_check';
alter table public.aim_account_documents drop constraint aim_account_documents_kind_check;
alter table public.aim_account_documents add constraint aim_account_documents_kind_check check(kind in ('chat','project','favorites','preferences','connectors','activity','memory'));
create or replace function public.aim_put_account_document(p_document jsonb,p_account_id uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare v public.aim_account_documents; expected bigint=(p_document->>'revision')::bigint; begin
  perform aim_require_live_session();
  if p_account_id is distinct from auth.uid() then raise exception 'account_changed' using errcode='42501'; end if;
  if expected is null or expected<0 or (p_document->>'kind') not in ('chat','project','favorites','preferences','connectors','activity','memory') or octet_length(p_document->>'payload')>16000000 then raise exception 'invalid_document'; end if;
  if p_document->>'kind'='activity' then
    if ((p_document->>'payload')::jsonb->>'accountID')::uuid is distinct from auth.uid()
      or ((p_document->>'payload')::jsonb->>'id')::uuid is distinct from (p_document->>'id')::uuid then
      raise exception 'activity_owner_mismatch' using errcode='42501'; end if;
  end if;
  if p_document->>'kind'='memory' then
    if jsonb_typeof((p_document->>'payload')::jsonb->'entries') is distinct from 'array' then raise exception 'invalid_memory'; end if;
  end if;
  -- Unique key and conditional upsert cover the absent-row race too.
  insert into aim_account_documents(user_id,id,kind,payload,revision,deleted)
    values(auth.uid(),(p_document->>'id')::uuid,p_document->>'kind',p_document->>'payload',1,coalesce((p_document->>'deleted')::boolean,false))
    on conflict(user_id,id) do update set payload=excluded.payload,revision=aim_account_documents.revision+1,deleted=excluded.deleted,updated_at=now()
      where aim_account_documents.revision=expected and aim_account_documents.kind=excluded.kind
    returning * into v;
  if not found or (v.revision=1 and expected<>0) then raise exception 'revision_conflict' using errcode='40001'; end if;
  return jsonb_build_object('id',v.id,'kind',v.kind,'payload',v.payload,'revision',v.revision,'deleted',v.deleted);
end $$;

create table public.aim_push_installations(
  user_id uuid not null, installation_id uuid primary key, account_session_id uuid not null,
  token text not null check(token ~ '^[0-9a-f]{64,200}$'), topic text not null check(topic ~ '^[A-Za-z0-9][A-Za-z0-9.-]{2,200}$'),
  environment text not null check(environment in ('sandbox','production')), categories text[] not null,
  viewed_conversation uuid, foreground boolean not null default false, presence_at timestamptz not null default now(),
  registration_version uuid not null default gen_random_uuid(),
  revoked_at timestamptz, updated_at timestamptz not null default now(), unique(user_id,installation_id));
create unique index aim_push_active_token on public.aim_push_installations(token,topic,environment) where revoked_at is null;
create table public.aim_push_events(
  user_id uuid not null, id uuid not null, task_id uuid not null, conversation_id uuid not null,
  category text not null check(category in ('response','task','question','approval','failure')),
  created_at timestamptz not null default now(), primary key(user_id,id));
create table public.aim_push_deliveries(
  user_id uuid not null, event_id uuid not null, installation_id uuid not null,
  state text not null default 'pending' check(state in ('pending','sending','sent','suppressed','failed')),
  lease_until timestamptz, lease_token uuid, registration_version uuid, attempts integer not null default 0 check(attempts between 0 and 8),
  next_attempt_at timestamptz not null default now(), last_status integer, updated_at timestamptz not null default now(),
  primary key(event_id,installation_id), foreign key(user_id,event_id) references public.aim_push_events(user_id,id),
  foreign key(user_id,installation_id) references public.aim_push_installations(user_id,installation_id));
create index aim_push_deliveries_due on public.aim_push_deliveries(next_attempt_at,updated_at) where state in ('pending','sending');
alter table public.aim_push_installations enable row level security;
alter table public.aim_push_events enable row level security;
alter table public.aim_push_deliveries enable row level security;
revoke all on public.aim_push_installations,public.aim_push_events,public.aim_push_deliveries from public,anon,authenticated;

create function public.aim_register_push(p_installation uuid,p_token text,p_topic text,p_environment text,p_categories text[]) returns void language plpgsql security definer set search_path=public as $$
declare sid uuid=aim_require_live_session(); begin
 if p_categories is null or not p_categories <@ array['response','task','question','approval','failure']::text[] then raise exception 'invalid_categories'; end if;
 if exists(select 1 from aim_push_installations where installation_id=p_installation and user_id<>auth.uid()) then raise exception 'installation_owner_mismatch' using errcode='42501'; end if;
 -- Serialize concurrent bindings of one physical token; the partial unique index enforces this invariant too.
 perform pg_advisory_xact_lock(hashtextextended(p_token||':'||p_topic||':'||p_environment,0));
 update aim_push_installations set revoked_at=now() where token=p_token and topic=p_topic and environment=p_environment
   and installation_id<>p_installation and revoked_at is null;
 insert into aim_push_installations(user_id,installation_id,account_session_id,token,topic,environment,categories)
 values(auth.uid(),p_installation,sid,p_token,p_topic,p_environment,p_categories)
 on conflict(installation_id) do update set account_session_id=sid,token=excluded.token,topic=excluded.topic,environment=excluded.environment,categories=excluded.categories,registration_version=case when aim_push_installations.token=excluded.token and aim_push_installations.topic=excluded.topic and aim_push_installations.environment=excluded.environment and aim_push_installations.account_session_id=excluded.account_session_id and aim_push_installations.revoked_at is null then aim_push_installations.registration_version else gen_random_uuid() end,revoked_at=null,updated_at=now()
 where aim_push_installations.user_id=auth.uid();
 if not found then raise exception 'installation_owner_mismatch' using errcode='42501'; end if;
end $$;
create function public.aim_push_presence(p_installation uuid,p_foreground boolean,p_conversation uuid default null) returns void language plpgsql security definer set search_path=public as $$
declare sid uuid=aim_require_live_session(); begin
 update aim_push_installations set foreground=p_foreground,viewed_conversation=p_conversation,presence_at=now()
 where installation_id=p_installation and user_id=auth.uid() and account_session_id=sid and revoked_at is null;
end $$;
create function public.aim_unregister_push(p_installation uuid) returns void language plpgsql security definer set search_path=public as $$
begin perform aim_require_live_session(); update aim_push_installations set revoked_at=now() where installation_id=p_installation and user_id=auth.uid(); end $$;
create function public.aim_enqueue_push(p_event uuid,p_task uuid,p_conversation uuid,p_category text,p_account_id uuid) returns void language plpgsql security definer set search_path=public as $$
begin
 perform aim_require_live_session();
 if p_account_id is distinct from auth.uid() then raise exception 'account_changed' using errcode='42501'; end if;
 if p_event is null or p_task is null or p_conversation is null or p_category is null or p_category not in ('response','task','question','approval','failure') then raise exception 'invalid_event'; end if;
 -- The same root event is idempotent; sub-agent progress is never a notification category.
 insert into aim_push_events(user_id,id,task_id,conversation_id,category) values(auth.uid(),p_event,p_task,p_conversation,p_category) on conflict do nothing;
 -- Check after the unique-key insert, covering competing absent-row writers too.
 if exists(select 1 from aim_push_events where id=p_event and user_id=auth.uid() and
     (task_id<>p_task or conversation_id<>p_conversation or category<>p_category)) then raise exception 'event_conflict' using errcode='40001'; end if;
 insert into aim_push_deliveries(user_id,event_id,installation_id)
 select auth.uid(),p_event,i.installation_id from aim_push_installations i where i.user_id=auth.uid() and i.revoked_at is null and p_category=any(i.categories)
 on conflict do nothing;
end $$;

-- Worker functions are service-role only. A lease token fences crashed/overlapping workers.
-- Retries do not need a new client event: an authenticated server scheduler claims due rows.
create function public.aim_claim_push() returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare result jsonb; begin
 if auth.role()<>'service_role' then raise exception 'worker_only' using errcode='42501'; end if;
 update aim_push_installations i set revoked_at=now() where i.revoked_at is null and
   (not exists(select 1 from auth.sessions s where s.id=i.account_session_id and s.user_id=i.user_id and (s.not_after is null or s.not_after>now()))
    or exists(select 1 from aim_account_session_metadata m where m.id=i.account_session_id and m.revoked_at is not null));
 update aim_push_deliveries d set state='suppressed',lease_until=null,lease_token=null,updated_at=now() from aim_push_installations i,aim_push_events e
 where i.installation_id=d.installation_id and i.user_id=d.user_id and e.id=d.event_id and e.user_id=d.user_id and d.state in ('pending','sending') and
 (i.revoked_at is not null or not e.category=any(i.categories) or (i.foreground and i.presence_at>now()-interval '60 seconds') or e.created_at<now()-interval '1 hour');
 update aim_push_deliveries set state='failed',lease_until=null,lease_token=null,updated_at=now()
   where attempts>=8 and (state='pending' or state='sending' and lease_until<=now());
 -- Eight jobs, four at a time; 10-second APNs + two 5-second RPC calls stay below the lease.
 with picked as (
   select d.event_id,d.installation_id from aim_push_deliveries d
   where d.attempts<8 and ((d.state='pending' and d.next_attempt_at<=now()) or (d.state='sending' and d.lease_until<=now()))
   order by d.next_attempt_at,d.updated_at limit 8 for update skip locked
 ), leased as (
   update aim_push_deliveries d set state='sending',lease_until=now()+interval '2 minutes',lease_token=gen_random_uuid(),
     registration_version=i.registration_version,attempts=d.attempts+1,updated_at=now()
   from picked p,aim_push_installations i where d.event_id=p.event_id and d.installation_id=p.installation_id
     and i.installation_id=d.installation_id and i.user_id=d.user_id returning d.*
 )
 select coalesce(jsonb_agg(jsonb_build_object('account',d.user_id,'event',d.event_id,'installation',i.installation_id,
   'lease',d.lease_token,'expires',floor(extract(epoch from e.created_at+interval '1 hour')),'token',i.token,'topic',i.topic,'environment',i.environment,'conversation',e.conversation_id,'task',e.task_id,'category',e.category)),'[]')
 into result from leased d join aim_push_installations i on i.installation_id=d.installation_id and i.user_id=d.user_id
   join aim_push_events e on e.id=d.event_id and e.user_id=d.user_id;
 return result;
end $$;
create function public.aim_validate_push(p_event uuid,p_installation uuid,p_lease uuid) returns boolean language plpgsql security definer set search_path=public,auth as $$
declare allowed boolean; begin
 if auth.role()<>'service_role' then raise exception 'worker_only' using errcode='42501'; end if;
 -- Rotated tokens/sessions must never be sent or revoked by the previous lease. Retry with the new registration.
 update aim_push_deliveries d set state='pending',lease_until=null,lease_token=null,next_attempt_at=now(),updated_at=now()
 from aim_push_installations i where d.event_id=p_event and d.installation_id=p_installation and d.lease_token=p_lease
   and d.state='sending' and i.installation_id=d.installation_id and i.user_id=d.user_id and d.registration_version<>i.registration_version;
 select exists(select 1 from aim_push_deliveries d join aim_push_installations i on i.installation_id=d.installation_id and i.user_id=d.user_id
 join aim_push_events e on e.id=d.event_id and e.user_id=d.user_id join auth.sessions s on s.id=i.account_session_id and s.user_id=i.user_id
 where d.event_id=p_event and d.installation_id=p_installation and d.lease_token=p_lease and d.state='sending' and d.lease_until>now() and i.revoked_at is null
 and d.registration_version=i.registration_version and (s.not_after is null or s.not_after>now())
 and not exists(select 1 from aim_account_session_metadata m where m.id=s.id and m.revoked_at is not null)
 and e.category=any(i.categories) and not (i.foreground and i.presence_at>now()-interval '60 seconds') and e.created_at>now()-interval '1 hour') into allowed;
 if not allowed then update aim_push_deliveries set state='suppressed',lease_until=null,lease_token=null,updated_at=now()
   where event_id=p_event and installation_id=p_installation and lease_token=p_lease and state='sending' and lease_until>now(); end if;
 return allowed;
end $$;
create function public.aim_finish_push(p_event uuid,p_installation uuid,p_lease uuid,p_status integer,p_retry_after integer default null) returns void language plpgsql security definer set search_path=public as $$
declare version uuid; begin
 if auth.role()<>'service_role' then raise exception 'worker_only' using errcode='42501'; end if;
 if p_status is null or p_status<100 or p_status>599 then raise exception 'invalid_status'; end if;
 -- A completed/expired lease cannot mutate a newer attempt or a newer device registration.
 update aim_push_deliveries d set
   state=case when p_status=200 then 'sent' when (p_status>=500 or p_status=429) and d.attempts<8 then 'pending' else 'failed' end,
   next_attempt_at=now()+make_interval(secs=>greatest(least(coalesce(p_retry_after,0),3600),least(900,30*power(2,greatest(0,d.attempts-1)))::integer)),
   last_status=p_status,lease_until=null,lease_token=null,updated_at=now()
 where d.event_id=p_event and d.installation_id=p_installation and d.lease_token=p_lease and d.state='sending' and d.lease_until>now()
 returning d.registration_version into version;
 if p_status=410 and version is not null then update aim_push_installations set revoked_at=now()
   where installation_id=p_installation and registration_version=version; end if;
end $$;
create function public.aim_push_events_since(p_after timestamptz default null) returns jsonb language plpgsql security definer set search_path=public as $$
declare result jsonb;
begin
 perform aim_require_live_session();
 select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'conversation',e.conversation_id,'category',e.category,'created_at',e.created_at)),'[]') into result
 from (select id,conversation_id,category,created_at from aim_push_events where user_id=auth.uid()
   and created_at>=coalesce(p_after,now()-interval '5 minutes') order by created_at desc,id desc limit 100) e;
 return result;
end $$;
-- Server-owned timestamps and UUID tie-breakers avoid device-clock drift and pagination gaps.
create index aim_push_events_feed on public.aim_push_events(user_id,created_at,id);
create function public.aim_push_event_page(p_created_at timestamptz default null,p_event_id uuid default null,p_overlap boolean default true)
returns jsonb language plpgsql security definer set search_path=public as $$
declare result jsonb; next_cursor jsonb; more boolean;
begin
 perform aim_require_live_session();
 if (p_created_at is null) <> (p_event_id is null) then raise exception 'invalid_cursor'; end if;
 with batch as materialized (
   select id,conversation_id,category,created_at from aim_push_events
   where user_id=auth.uid() and created_at>=now()-interval '1 hour'
   and case when p_created_at is null then created_at>=now()-interval '5 minutes'
       when coalesce(p_overlap,false) then created_at>=p_created_at-interval '60 seconds'
       else (created_at,id)>(p_created_at,p_event_id) end
   order by created_at,id limit 101
 ), page as (select * from batch order by created_at,id limit 100)
 select coalesce((select jsonb_agg(jsonb_build_object('id',id,'conversation',conversation_id,'category',category,'created_at',created_at) order by created_at,id) from page),'[]'::jsonb),
   (select jsonb_build_object('id',id,'created_at',created_at) from page order by created_at desc,id desc limit 1),
   (select count(*)>100 from batch)
 into result,next_cursor,more;
 if next_cursor is null and p_created_at is not null then next_cursor=jsonb_build_object('created_at',p_created_at,'id',p_event_id); end if;
 return jsonb_build_object('events',result,'cursor',next_cursor,'has_more',more);
end $$;
revoke all on function public.aim_push_event_page(timestamptz,uuid,boolean) from public,anon,authenticated;
grant execute on function public.aim_push_event_page(timestamptz,uuid,boolean) to authenticated;
revoke all on function public.aim_push_events_since(timestamptz) from public,anon,authenticated;
grant execute on function public.aim_push_events_since(timestamptz) to authenticated;
revoke all on function public.aim_register_push(uuid,text,text,text,text[]),public.aim_push_presence(uuid,boolean,uuid),public.aim_unregister_push(uuid),public.aim_enqueue_push(uuid,uuid,uuid,text,uuid),public.aim_claim_push(),public.aim_validate_push(uuid,uuid,uuid),public.aim_finish_push(uuid,uuid,uuid,integer,integer) from public,anon,authenticated;
grant execute on function public.aim_register_push(uuid,text,text,text,text[]),public.aim_push_presence(uuid,boolean,uuid),public.aim_unregister_push(uuid),public.aim_enqueue_push(uuid,uuid,uuid,text,uuid) to authenticated;
grant execute on function public.aim_claim_push(),public.aim_validate_push(uuid,uuid,uuid),public.aim_finish_push(uuid,uuid,uuid,integer,integer) to service_role;
notify pgrst,'reload schema';
commit;
