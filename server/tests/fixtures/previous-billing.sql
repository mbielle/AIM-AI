-- Synthetic historical deployment shape; test-only, never in bootstrap/deploy.
create schema aim_billing_private;
create table aim_billing_private.grants(account_id uuid,external_id text);
insert into aim_billing_private.grants values('10000000-0000-0000-0000-000000000001','fixture-history');
alter function public.remote_send_command(uuid,text,uuid,uuid,text,text,jsonb,text,text) set schema aim_billing_private;
alter function aim_billing_private.remote_send_command(uuid,text,uuid,uuid,text,text,jsonb,text,text) rename to remote_send_command_pre_billing;
alter function public.aim_remote_command_authorized(uuid,text,uuid,text) set schema aim_billing_private;
alter function aim_billing_private.aim_remote_command_authorized(uuid,text,uuid,text) rename to remote_host_authorized_pre_billing;
create function public.remote_send_command(p_device_id uuid,p_device_secret text,p_command_id uuid,p_machine_id uuid,p_session_id text,p_type text,p_payload jsonb,p_unlock_token text default null,p_mode text default null) returns jsonb language sql security definer set search_path='' as $$ select '{"ok":false,"error":"subscription_required"}'::jsonb $$;
create function public.aim_remote_command_authorized(p_machine_id uuid,p_secret text,p_command_id uuid,p_conversation_id text default null) returns boolean language sql security definer set search_path='' as $$select false$$;
create function public.get_aim_entitlement(p_environment text default 'production') returns jsonb language sql security definer set search_path='' as $$select '{"access_until":null}'::jsonb$$;
create function public.start_aim_trial(p_environment text default 'production') returns jsonb language sql security definer set search_path='' as $$select '{"trial_available":true}'::jsonb$$;
