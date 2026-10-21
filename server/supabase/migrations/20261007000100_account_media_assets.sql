-- PREPARED ONLY: apply this single additive migration after explicit review/approval.
-- No existing migration, account document, provider credential or APNs object is changed.
begin;
-- Operation-aware SELECT is necessary for tombstone-first deletion through Storage,
-- while still denying fresh downloads/signatures of deleted bytes.
do $$ begin
  if to_regprocedure('storage.allow_any_operation(text[])') is null then
    raise exception 'storage_operation_helpers_required';
  end if;
end $$;
create table public.account_media_assets (
  account_id uuid not null references auth.users(id) on delete cascade,
  id uuid not null,
  job_id uuid not null,
  payload jsonb not null,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  primary key(account_id,id),
  unique(account_id,job_id),
  check(jsonb_typeof(payload)='object'),
  check(octet_length(payload::text)<=131072)
);
alter table public.account_media_assets enable row level security;
revoke all on public.account_media_assets from public,anon,authenticated;
grant select on public.account_media_assets to authenticated;
create policy account_media_read on public.account_media_assets for select to authenticated
using(account_id=(select auth.uid()) and (select public.aim_session_is_live()));

create function public.aim_put_media_asset(p_account_id uuid,p_asset jsonb) returns void
language plpgsql security definer set search_path=public,pg_temp as $$
declare aid uuid; jid uuid; existing public.account_media_assets; tombstone boolean; begin
  perform public.aim_require_live_session();
  if p_account_id is distinct from auth.uid() or (p_asset->>'accountID')::uuid is distinct from auth.uid() then
    raise exception 'account_changed' using errcode='42501';
  end if;
  aid=(p_asset->>'id')::uuid; jid=(p_asset->>'jobID')::uuid;
  tombstone=coalesce(p_asset->'deletedAt','null'::jsonb)<>'null'::jsonb;
  if aid is null or jid is null or aid<>jid or coalesce(p_asset->>'kind','') not in ('image','video')
    or coalesce(p_asset->>'provider','') not in ('openRouter','blackForestLabs')
    or coalesce(p_asset->>'mimeType','') not in ('image/png','image/jpeg','image/webp','video/mp4')
    or (p_asset->>'kind'='image' and p_asset->>'mimeType'='video/mp4')
    or (p_asset->>'kind'='video' and p_asset->>'mimeType'<>'video/mp4')
    or coalesce((p_asset->>'byteCount')::bigint,0) not between 1 and 536870912
    or coalesce(p_asset->>'sha256','') !~ '^[0-9a-f]{64}$'
    or octet_length(p_asset::text)>131072
    or length(coalesce(p_asset->>'modelID','')) not between 1 and 256 then raise exception 'invalid_media_asset'; end if;
  -- Unique job identity prevents a sync reader from inventing another cost/result asset.
  insert into public.account_media_assets(account_id,id,job_id,payload,deleted_at)
    values(auth.uid(),aid,jid,p_asset,case when tombstone then now() else null end)
    on conflict(account_id,id) do nothing;
  select * into existing from public.account_media_assets where account_id=auth.uid() and id=aid for update;
  if existing.job_id<>jid or existing.payload->>'sha256'<>p_asset->>'sha256' then raise exception 'immutable_media_mismatch'; end if;
  -- A stale/offline upload cannot remove a deletion, even with a later device clock.
  if existing.deleted_at is not null then return; end if;
  if tombstone then update public.account_media_assets set deleted_at=now(),payload=p_asset where account_id=auth.uid() and id=aid; end if;
end $$;
revoke all on function public.aim_put_media_asset(uuid,jsonb) from public,anon;
grant execute on function public.aim_put_media_asset(uuid,jsonb) to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('account-media','account-media',false,536870912,array['image/png','image/jpeg','image/webp','video/mp4']);
-- Paths are account UUID / asset UUID / result. The storage owner is never inferred from a title.
create policy aim_media_object_read on storage.objects for select to authenticated using(
  bucket_id='account-media' and (storage.foldername(name))[1]=(select auth.uid())::text
  and (select public.aim_session_is_live())
  and (storage.allow_any_operation(array['object.delete','object.delete_many'])
    or not exists(select 1 from public.account_media_assets a where a.account_id=auth.uid()
      and a.id::text=(storage.foldername(name))[2] and a.deleted_at is not null)));
create policy aim_media_object_insert on storage.objects for insert to authenticated with check(
  bucket_id='account-media' and (storage.foldername(name))[1]=(select auth.uid())::text
  and array_length(storage.foldername(name),1)=2 and storage.filename(name)='result'
  and (storage.foldername(name))[2] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  and (select public.aim_session_is_live())
  and not exists(select 1 from public.account_media_assets a where a.account_id=auth.uid()
      and a.id::text=(storage.foldername(name))[2] and a.deleted_at is not null));
create policy aim_media_object_update on storage.objects for update to authenticated using(
  bucket_id='account-media' and (storage.foldername(name))[1]=(select auth.uid())::text
  and (select public.aim_session_is_live()))
with check(bucket_id='account-media' and (storage.foldername(name))[1]=(select auth.uid())::text
  and array_length(storage.foldername(name),1)=2 and storage.filename(name)='result'
  and (storage.foldername(name))[2] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  and (select public.aim_session_is_live())
  and not exists(select 1 from public.account_media_assets a where a.account_id=auth.uid()
      and a.id::text=(storage.foldername(name))[2] and a.deleted_at is not null));
create policy aim_media_object_delete on storage.objects for delete to authenticated using(
  bucket_id='account-media' and (storage.foldername(name))[1]=(select auth.uid())::text
  and (select public.aim_session_is_live()));
commit;
