-- 2026-10-10 (authorized by Mathieu): a business conflict raised with SQLSTATE 40001
-- (serialization_failure) makes PostgREST retry the transaction without end (Supabase
-- troubleshooting: "high CPU and infinite transaction retries when using custom error codes in
-- RPC functions"). One stale write looped inside the database (207k revision_conflict errors in
-- an hour) until PostgREST could no longer reach it. Conflicts are now HTTP 409 (PT409), returned
-- once; clients recognise them by their message. Bodies are otherwise identical to production.
begin;
CREATE OR REPLACE FUNCTION public.aim_put_account_document(p_document jsonb, p_account_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  if not found or (v.revision=1 and expected<>0) then raise sqlstate 'PT409' using message='revision_conflict'; end if;
  return jsonb_build_object('id',v.id,'kind',v.kind,'payload',v.payload,'revision',v.revision,'deleted',v.deleted);
end $function$;

CREATE OR REPLACE FUNCTION public.aim_enqueue_push(p_event uuid, p_task uuid, p_conversation uuid, p_category text, p_account_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
 perform aim_require_live_session();
 if p_account_id is distinct from auth.uid() then raise exception 'account_changed' using errcode='42501'; end if;
 if p_event is null or p_task is null or p_conversation is null or p_category is null or p_category not in ('response','task','question','approval','failure') then raise exception 'invalid_event'; end if;
 -- The same root event is idempotent; sub-agent progress is never a notification category.
 insert into aim_push_events(user_id,id,task_id,conversation_id,category) values(auth.uid(),p_event,p_task,p_conversation,p_category) on conflict do nothing;
 -- Check after the unique-key insert, covering competing absent-row writers too.
 if exists(select 1 from aim_push_events where id=p_event and user_id=auth.uid() and
     (task_id<>p_task or conversation_id<>p_conversation or category<>p_category)) then raise sqlstate 'PT409' using message='event_conflict'; end if;
 insert into aim_push_deliveries(user_id,event_id,installation_id)
 select auth.uid(),p_event,i.installation_id from aim_push_installations i where i.user_id=auth.uid() and i.revoked_at is null and p_category=any(i.categories)
 on conflict do nothing;
end $function$;
commit;
