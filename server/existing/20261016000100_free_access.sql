-- EXISTING installations only; review on a restored copy before production.
-- No rows, pairing keys, sessions, financial history or provider secrets are deleted.
begin;
create schema if not exists aim_transition_private;
revoke all on schema aim_transition_private from public,anon,authenticated;
create table if not exists aim_transition_private.function_backups(name text primary key,definition text not null);
do $$ declare signature text; begin
 foreach signature in array array['public.remote_send_command(uuid,text,uuid,uuid,text,text,jsonb,text,text)','public.aim_remote_command_authorized(uuid,text,uuid,text)','public.get_aim_entitlement(text)','public.start_aim_trial(text)'] loop
 if to_regprocedure(signature) is null then raise exception 'transition_source_missing: %',signature;end if;
 insert into aim_transition_private.function_backups values(signature,pg_get_functiondef(to_regprocedure(signature))) on conflict do nothing;
 end loop;
 if to_regprocedure('aim_billing_private.remote_send_command_pre_billing(uuid,text,uuid,uuid,text,text,jsonb,text,text)') is null or to_regprocedure('aim_billing_private.remote_host_authorized_pre_billing(uuid,text,uuid,text)') is null then raise exception 'review_security_baseline_before_transition';end if;
end $$;
-- Delegate to the preserved authoritative security implementation, not a permissive stub.
create or replace function public.remote_send_command(p_device_id uuid,p_device_secret text,p_command_id uuid,p_machine_id uuid,p_session_id text,p_type text,p_payload jsonb,p_unlock_token text default null,p_mode text default null) returns jsonb language plpgsql security definer set search_path='' as $$ begin
return aim_billing_private.remote_send_command_pre_billing(p_device_id,p_device_secret,p_command_id,p_machine_id,p_session_id,p_type,p_payload,p_unlock_token,p_mode);end $$;
create or replace function public.aim_remote_command_authorized(p_machine_id uuid,p_secret text,p_command_id uuid,p_conversation_id text default null) returns boolean language sql security definer set search_path='' as $$
select aim_billing_private.remote_host_authorized_pre_billing(p_machine_id,p_secret,p_command_id,p_conversation_id) $$;
-- Legacy cache-shaped availability response, not a subscription or monetary grant.
-- New clients do not call this RPC. Session ownership/liveness is still mandatory.
create or replace function public.get_aim_entitlement(p_environment text default 'production') returns jsonb language plpgsql security definer set search_path='' as $$ begin
perform public.aim_require_live_session();
if p_environment not in ('production','sandbox') then raise exception 'invalid_environment';end if;
return jsonb_build_object('account_id',auth.uid(),'environment',p_environment,'server_time',now(),'access_until',now()+interval '24 hours','source','free','trial_available',false,'tester',false);
end $$;
create or replace function public.start_aim_trial(p_environment text default 'production') returns jsonb language sql security definer set search_path='' as $$ select public.get_aim_entitlement(p_environment) $$;
revoke all on function public.remote_send_command(uuid,text,uuid,uuid,text,text,jsonb,text,text),public.aim_remote_command_authorized(uuid,text,uuid,text),public.get_aim_entitlement(text),public.start_aim_trial(text) from public,anon;
grant execute on function public.remote_send_command(uuid,text,uuid,uuid,text,text,jsonb,text,text),public.aim_remote_command_authorized(uuid,text,uuid,text) to authenticated,service_role;
grant execute on function public.get_aim_entitlement(text),public.start_aim_trial(text) to authenticated;
commit;
