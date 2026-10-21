-- Account-scoped export/deletion support; no service-role exposed to clients.
create function public.aim_account_storage_paths()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  result jsonb;
begin
  perform public.aim_require_live_session();
  select coalesce(jsonb_agg(jsonb_build_object('bucket', bucket_id, 'name', name)), '[]'::jsonb)
    into result
    from storage.objects
    where (storage.foldername(name))[1] = auth.uid()::text;
  return result;
end;
$$;
revoke all on function public.aim_account_storage_paths() from public, anon;
grant execute on function public.aim_account_storage_paths() to authenticated;

-- Explicit grants make a fresh installation independent of dashboard defaults.
grant usage on schema public to authenticated;
grant select, insert, update, delete on
  public.profiles, public.projects, public.conversations, public.messages,
  public.project_files, public.user_preferences, public.user_memory_documents,
  public.generated_images, public.generated_videos, public.user_connectors
  to authenticated;

-- Deliberate public maintenance entrypoints; implementation helper stays private.
create function public.aim_maintenance_session()
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  perform public.aim_require_live_session();
  return true;
end;
$$;

create function public.aim_export_account_documents()
returns setof public.aim_account_documents
language plpgsql security definer set search_path = '' as $$
begin
  perform public.aim_require_live_session();
  return query select * from public.aim_account_documents where user_id = auth.uid() order by id;
end;
$$;
revoke all on function public.aim_maintenance_session(), public.aim_export_account_documents()
  from public, anon;
grant execute on function public.aim_maintenance_session(), public.aim_export_account_documents()
  to authenticated;
