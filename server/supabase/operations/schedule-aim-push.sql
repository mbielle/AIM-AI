-- PREPARED, NOT EXECUTED. Admin deployment step, after migration 003 and worker secrets.
-- Enable pg_cron + pg_net in the dashboard first; store these two values in Vault:
-- aim_push_worker_url: https://<project-ref>.supabase.co/functions/v1/aim-push-worker
-- aim_push_worker_secret: the SAME 64-character random hex as Edge AIM_PUSH_WORKER_SECRET.
-- Neither the Supabase service-role key nor the Apple .p8 belongs in cron/Vault headers.
begin;
do $$ begin
 if to_regclass('cron.job') is null or to_regclass('vault.decrypted_secrets') is null
   or to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then
   raise exception 'enable_cron_net_vault_first';
 end if;
end $$;
create or replace function aim_session_private.dispatch_push_tick() returns void
language plpgsql security definer set search_path=pg_catalog as $$
declare endpoint text; worker_secret text; begin
 if not exists(select 1 from public.aim_push_deliveries where
   (state='pending' and next_attempt_at<=now()) or (state='sending' and lease_until<=now())) then return; end if;
 select decrypted_secret into endpoint from vault.decrypted_secrets where name='aim_push_worker_url';
 select decrypted_secret into worker_secret from vault.decrypted_secrets where name='aim_push_worker_secret';
 if endpoint is null or endpoint !~ '^https://[a-z0-9]+\.supabase\.co/functions/v1/aim-push-worker$'
   or worker_secret is null or worker_secret !~ '^[a-fA-F0-9]{64}$' then
   raise exception 'push_scheduler_not_configured';
 end if;
 perform net.http_post(url=>endpoint,headers=>jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||worker_secret),
   body=>'{}'::jsonb,timeout_milliseconds=>55000);
end $$;
revoke all on function aim_session_private.dispatch_push_tick() from public,anon,authenticated,service_role;
-- Re-running this *deployment configuration*, unlike data migrations, replaces the named job.
select cron.unschedule(jobid) from cron.job where jobname='aim-push-retry-minute';
select cron.schedule('aim-push-retry-minute','* * * * *','select aim_session_private.dispatch_push_tick();');
commit;
