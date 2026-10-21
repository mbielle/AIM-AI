-- Prepared migration only. Live contract read-only inspection: 2026-10-06.
-- Strict function hashes abort the transaction on drift; no production apply yet.
-- Auth, pairing, encryption and command idempotency are retained. Existing accounts
-- keep Code/Agent protection unless their existing enabled preference is false.
begin;

create table if not exists public.remote_security_policies (
  user_id uuid primary key references auth.users(id) on delete cascade,
  protected_modes text[] not null default array['code','agent']::text[],
  revision bigint not null default 1 check (revision > 0),
  updated_at timestamptz not null default now(),
  check (protected_modes <@ array['chat','code','agent']::text[] and cardinality(protected_modes) <= 3)
);
alter table public.remote_security_policies enable row level security;
-- Policies are available only through paired, authenticated functions.
revoke all on public.remote_security_policies from anon, authenticated;

create or replace function public.remote_security_policy(
  p_device_id uuid, p_device_secret text, p_unlock_token text default null
) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_modes text[]; v_revision bigint;
begin
  if auth.uid() is null then return jsonb_build_object('ok',false,'error','not_authenticated'); end if;
  if not exists (select 1 from remote_devices where id=p_device_id and user_id=auth.uid()
    and revoked_at is null and (expires_at is null or expires_at>now())
    and secret_hash=encode(digest(p_device_secret,'sha256'),'hex')) then
    return jsonb_build_object('ok',false,'error','device_not_paired');
  end if;
  select protected_modes,revision into v_modes,v_revision from remote_security_policies where user_id=auth.uid();
  if not remote_unlock_actif(auth.uid()) then v_modes:=array[]::text[];
  else v_modes:=coalesce(v_modes,array['code','agent']::text[]); end if;
  return jsonb_build_object('ok',true,'policy',jsonb_build_object('version',1,
    'revision',coalesce(v_revision,0),'protected_modes',to_jsonb(v_modes),
    'unlock_authorized',remote_unlock_valide(auth.uid(),p_device_id,p_unlock_token)));
end $$;

create or replace function public.remote_set_security_policy(
  p_device_id uuid, p_device_secret text, p_protected_modes text[],
  p_expected_revision bigint, p_unlock_token text default null
) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_modes text[]; v_revision bigint; v_configured boolean;
begin
  if auth.uid() is null then return jsonb_build_object('ok',false,'error','not_authenticated'); end if;
  -- Serialize account policy edits; compare the revision before committing.
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,61006));
  perform 1 from remote_devices where id=p_device_id and user_id=auth.uid()
    and revoked_at is null and (expires_at is null or expires_at>now())
    and secret_hash=encode(digest(p_device_secret,'sha256'),'hex') for share;
  if not found then return jsonb_build_object('ok',false,'error','device_not_paired'); end if;
  if p_protected_modes is null or p_expected_revision is null or p_expected_revision<0
    or cardinality(p_protected_modes)>3 or array_position(p_protected_modes,null) is not null
    or not p_protected_modes <@ array['chat','code','agent']::text[]
    or cardinality(p_protected_modes)<>(select count(distinct m) from unnest(p_protected_modes) m) then
    return jsonb_build_object('ok',false,'error','invalid_policy');
  end if;
  select coalesce(array_agg(m order by m),array[]::text[]) into v_modes from unnest(p_protected_modes) m;
  v_configured:=exists(select 1 from remote_unlock_pin where user_id=auth.uid())
    or exists(select 1 from remote_unlock_credentials where user_id=auth.uid());
  if v_configured and not remote_unlock_valide(auth.uid(),p_device_id,p_unlock_token) then
    return jsonb_build_object('ok',false,'error','unlock_required');
  end if;
  if cardinality(v_modes)>0 and not v_configured then
    return jsonb_build_object('ok',false,'error','no_pin');
  end if;
  select revision into v_revision from remote_security_policies where user_id=auth.uid();
  if coalesce(v_revision,0)<>p_expected_revision then
    return jsonb_build_object('ok',false,'error','policy_conflict');
  end if;
  insert into remote_security_policies(user_id,protected_modes,revision)
    values(auth.uid(),v_modes,coalesce(v_revision,0)+1)
    on conflict(user_id) do update set protected_modes=excluded.protected_modes,
      revision=excluded.revision,updated_at=now();
  insert into remote_unlock_prefs(user_id,enabled,updated_at)
    values(auth.uid(),cardinality(v_modes)>0,now())
    on conflict(user_id) do update set enabled=excluded.enabled,updated_at=now();
  -- Other devices must confirm authorization under the changed policy.
  delete from remote_unlock_sessions where user_id=auth.uid() and device_id<>p_device_id;
  return remote_security_policy(p_device_id,p_device_secret,p_unlock_token);
end $$;

create or replace function public.remote_policy_requires_unlock(p_user uuid,p_type text,p_mode text)
returns boolean language plpgsql stable security definer set search_path=public as $$
declare v_modes text[];
begin
  if p_type='request_keys' then return false; end if;
  select protected_modes into v_modes from remote_security_policies where user_id=p_user;
  v_modes:=coalesce(v_modes,array['code','agent']::text[]);
  if p_type in ('run_command','stop_command','list_folders','create_folder','request_diff','request_detail',
    'start_preview','stop_preview','upload_attachment') then
    -- Shared filesystem/tool operations cannot evade protection by claiming Chat.
    return 'code'=any(v_modes) or 'agent'=any(v_modes);
  end if;
  if p_type='create_session' or p_type in (
    'user_message','approval_response','set_model','set_approval_mode','stop_generation','resume_turn',
    'request_history','rename_session','archive_session','delete_session',
    'goal_start','goal_status','goal_pause','goal_resume','goal_cancel','goal_correct','goal_accept',
    'goal_approval_response','goal_question_response') then
    if p_mode in ('chat','code','agent') then return p_mode=any(v_modes); end if;
  end if;
  -- Old or unknown sessionless commands are conservatively protected.
  return cardinality(v_modes)>0;
end $$;

-- Patch only the existing unlock predicate and session ownership lookup, never
-- replace the entire admission function or replay/change any command rows.
do $guard$
declare v_source text;
  v_old text := $old$    and p_type <> 'request_keys'
    and coalesce(v_mode, '') <> 'chat'$old$;
  v_session text := $old$where id = p_session_id and user_id = auth.uid()$old$;
  v_lookup text := $old$    limit 1;
  end if;

  if coalesce(v_exige, false)$old$;
begin
  v_source:=pg_get_functiondef('public.remote_send_command(uuid,text,uuid,uuid,text,text,jsonb,text,text)'::regprocedure);
  if md5(v_source)<>'4e076419134b76b62cb90da60198a99c'
    or position(v_lookup in v_source)=0
    or position(v_old in v_source)=0 or position(v_session in v_source)=0
    or position('remote_unlock_valide(auth.uid(), p_device_id, p_unlock_token)' in v_source)=0
    or position('command_conflict' in v_source)=0 then
    raise exception 'Remote admission drift: inspect and rebase policy migration';
  end if;
  v_source:=replace(v_source,v_old,'    and public.remote_policy_requires_unlock(auth.uid(), p_type, v_mode)');
  v_source:=replace(v_source,v_session,v_session||' and machine_id = p_machine_id');
  v_source:=replace(v_source,v_lookup,$new$    limit 1;
    if not found then
      return jsonb_build_object('ok',false,'error','invalid_session');
    end if;
  end if;

  if (coalesce(v_exige, false) or exists(select 1 from public.remote_security_policies where user_id=auth.uid()))$new$);
  execute v_source;
end $guard$;


-- Backward compatibility: older clients still see the enabled boolean, but all
-- account writes now use the same authorization and revision serialization.
do $guard$
begin
  if md5(pg_get_functiondef('public.remote_unlock_set_enabled(uuid,text,boolean,text)'::regprocedure))<>'28fe1e5d122d596c5ebff82ca7af4507' then
    raise exception 'Remote legacy toggle drift: inspect before applying';
  end if;
end $guard$;
create or replace function public.remote_unlock_set_enabled(
  p_device_id uuid,p_device_secret text,p_enabled boolean,p_unlock_token text default null
) returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_modes text[]; v_revision bigint; v_result jsonb;
begin
  if auth.uid() is null then return jsonb_build_object('ok',false,'error','not_authenticated'); end if;
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,61006));
  select protected_modes,revision into v_modes,v_revision from remote_security_policies where user_id=auth.uid();
  if not coalesce(p_enabled,true) then v_modes:=array[]::text[];
  elsif coalesce(cardinality(v_modes),0)=0 then v_modes:=array['code','agent']::text[]; end if;
  v_result:=remote_set_security_policy(p_device_id,p_device_secret,v_modes,coalesce(v_revision,0),p_unlock_token);
  if coalesce((v_result->>'ok')::boolean,false) then
    return jsonb_build_object('ok',true,'enabled',cardinality(v_modes)>0);
  end if;
  return v_result;
end $$;

revoke all on function public.remote_security_policy(uuid,text,text) from public,anon;
revoke all on function public.remote_set_security_policy(uuid,text,text[],bigint,text) from public,anon;
revoke all on function public.remote_policy_requires_unlock(uuid,text,text) from public,anon,authenticated;
grant execute on function public.remote_security_policy(uuid,text,text) to authenticated;
grant execute on function public.remote_set_security_policy(uuid,text,text[],bigint,text) to authenticated;
commit;
