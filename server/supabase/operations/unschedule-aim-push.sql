-- Admin-only, reversible stop. Delivery data, Apple keys, Vault values and shared extensions remain intact.
begin;
do $$ begin
 if to_regclass('cron.job') is not null then
   execute 'select cron.unschedule(jobid) from cron.job where jobname=''aim-push-retry-minute''';
 end if;
end $$;
drop function if exists aim_session_private.dispatch_push_tick();
commit;
