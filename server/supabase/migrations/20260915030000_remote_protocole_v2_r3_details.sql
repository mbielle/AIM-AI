-- R3 — détails lourds chiffrés à la demande.
-- Le serveur ne voit ni le manifeste ni les blocs en clair. Chaque objet est
-- privé, borné à ~1 Mio et rangé sous l'UID authentifié.

create table if not exists public.remote_transfers (
  id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  machine_id uuid not null references public.remote_machines(id) on delete cascade,
  session_id text not null references public.remote_sessions(id) on delete cascade,
  kind text not null check (kind in ('detail', 'attachment')),
  key_version integer not null check (key_version > 0),
  manifest jsonb not null check (jsonb_typeof(manifest) = 'string'),
  chunk_count integer not null check (chunk_count between 1 and 256),
  status text not null default 'uploading' check (status in ('uploading', 'ready', 'error')),
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (expires_at > created_at and expires_at <= created_at + interval '24 hours 5 minutes')
);

create index if not exists remote_transfers_owner_expiry_idx
  on public.remote_transfers (user_id, expires_at);
create index if not exists remote_transfers_session_idx
  on public.remote_transfers (session_id, created_at desc);

alter table public.remote_transfers enable row level security;
drop policy if exists remote_transfers_select_own on public.remote_transfers;
drop policy if exists remote_transfers_insert_own on public.remote_transfers;
drop policy if exists remote_transfers_update_own on public.remote_transfers;
drop policy if exists remote_transfers_delete_own on public.remote_transfers;
create policy remote_transfers_select_own on public.remote_transfers for select
  using (user_id = auth.uid());
create policy remote_transfers_insert_own on public.remote_transfers for insert
  with check (
    user_id = auth.uid()
    and exists (
      select 1 from public.remote_machines m
      where m.id = machine_id and m.user_id = auth.uid()
    )
    and exists (
      select 1 from public.remote_sessions s
      where s.id = session_id and s.machine_id = machine_id and s.user_id = auth.uid()
    )
  );
create policy remote_transfers_update_own on public.remote_transfers for update
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy remote_transfers_delete_own on public.remote_transfers for delete
  using (user_id = auth.uid());

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('remote-transfers', 'remote-transfers', false, 1048604, array['application/octet-stream'])
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists remote_transfers_objects_select_own on storage.objects;
drop policy if exists remote_transfers_objects_insert_own on storage.objects;
drop policy if exists remote_transfers_objects_update_own on storage.objects;
drop policy if exists remote_transfers_objects_delete_own on storage.objects;

create policy remote_transfers_objects_select_own on storage.objects for select
  using (
    bucket_id = 'remote-transfers'
    and (storage.foldername(name))[1] = auth.uid()::text
    and exists (
      select 1 from public.remote_transfers t
      where t.id::text = (storage.foldername(name))[3]
        and t.machine_id::text = (storage.foldername(name))[2]
        and t.user_id = auth.uid()
        and t.expires_at > now()
    )
  );
create policy remote_transfers_objects_insert_own on storage.objects for insert
  with check (
    bucket_id = 'remote-transfers'
    and (storage.foldername(name))[1] = auth.uid()::text
    and exists (
      select 1 from public.remote_transfers t
      where t.id::text = (storage.foldername(name))[3]
        and t.machine_id::text = (storage.foldername(name))[2]
        and t.user_id = auth.uid()
        and t.status = 'uploading'
        and t.expires_at > now()
    )
  );
create policy remote_transfers_objects_update_own on storage.objects for update
  using (
    bucket_id = 'remote-transfers'
    and (storage.foldername(name))[1] = auth.uid()::text
  ) with check (
    bucket_id = 'remote-transfers'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
create policy remote_transfers_objects_delete_own on storage.objects for delete
  using (
    bucket_id = 'remote-transfers'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

alter table public.remote_commands drop constraint if exists remote_commands_type_check;
alter table public.remote_commands add constraint remote_commands_type_check check (type = any (array[
  'user_message', 'approval_response', 'set_model', 'set_approval_mode', 'request_diff', 'start_preview',
  'stop_preview', 'run_command', 'stop_command', 'list_folders', 'create_folder', 'create_session',
  'stop_generation', 'resume_turn', 'request_keys', 'request_detail'
]::text[]));

do $$ begin
  alter publication supabase_realtime add table public.remote_transfers;
exception when duplicate_object then null; when undefined_object then null;
end $$;
