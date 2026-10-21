-- Additive transport vocabulary. Existing RLS, pairing, revocation, unlock and
-- RPC authorization remain authoritative. Qualify their dispatch before
-- advertising continuity_v1; this migration alone does not enable the feature.
do $$
declare existing_expression text;
begin
  select pg_get_expr(c.conbin, c.conrelid) into existing_expression
  from pg_constraint c
  where c.conrelid = 'public.remote_commands'::regclass
    and c.conname = 'remote_commands_type_check' and c.contype = 'c';
  if existing_expression is null then
    raise exception 'Missing existing Remote command constraint: inspect the deployed schema before migrating';
  end if;
  alter table public.remote_commands drop constraint remote_commands_type_check;
  execute format('alter table public.remote_commands add constraint remote_commands_type_check check ((%s) OR type = ANY (%L::text[]))',
    existing_expression,
    '{goal_start,goal_status,goal_pause,goal_resume,goal_cancel,goal_correct,goal_accept,goal_approval_response,goal_question_response}');
end $$;
