-- Additive Remote session management contract for iOS/Desktop rollout.
-- Safe to execute more than once.

alter table public.remote_sessions
  add column if not exists is_pinned boolean not null default false,
  add column if not exists archived_at timestamptz,
  add column if not exists project_id uuid references public.projects(id) on delete set null;

create index if not exists remote_sessions_active_priority_idx
  on public.remote_sessions (user_id, mode, is_pinned desc, updated_at desc)
  where archived_at is null;
create index if not exists remote_sessions_project_idx
  on public.remote_sessions (user_id, project_id, updated_at desc)
  where project_id is not null;

create or replace function public.remote_session_project_belongs_to_owner()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.project_id is not null and not exists (
    select 1 from public.projects p
    where p.id = new.project_id and p.user_id = new.user_id
  ) then
    raise exception 'remote_session_project_not_owned' using errcode = '23514';
  end if;
  return new;
end;
$$;
drop trigger if exists remote_sessions_project_owner on public.remote_sessions;
create trigger remote_sessions_project_owner
  before insert or update of project_id, user_id on public.remote_sessions
  for each row execute function public.remote_session_project_belongs_to_owner();

create table if not exists public.remote_session_attachments (
  id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  machine_id uuid not null references public.remote_machines(id) on delete cascade,
  session_id text not null references public.remote_sessions(id) on delete cascade,
  key_version integer not null check (key_version > 0),
  metadata jsonb not null check (jsonb_typeof(metadata) = 'string'),
  created_at timestamptz not null default now(),
  expires_at timestamptz
);

create index if not exists remote_session_attachments_session_idx
  on public.remote_session_attachments (user_id, session_id, created_at);

alter table public.remote_session_attachments enable row level security;
drop policy if exists remote_session_attachments_select_own on public.remote_session_attachments;
drop policy if exists remote_session_attachments_insert_own on public.remote_session_attachments;
drop policy if exists remote_session_attachments_update_own on public.remote_session_attachments;
drop policy if exists remote_session_attachments_delete_own on public.remote_session_attachments;
create policy remote_session_attachments_select_own on public.remote_session_attachments for select
  using (user_id = auth.uid());
create policy remote_session_attachments_insert_own on public.remote_session_attachments for insert
  with check (
    user_id = auth.uid()
    and exists (
      select 1 from public.remote_sessions s
      where s.id = session_id and s.machine_id = machine_id and s.user_id = auth.uid()
    )
  );
create policy remote_session_attachments_update_own on public.remote_session_attachments for update
  using (user_id = auth.uid())
  with check (
    user_id = auth.uid()
    and exists (
      select 1 from public.remote_sessions s
      where s.id = session_id and s.machine_id = machine_id and s.user_id = auth.uid()
    )
  );
create policy remote_session_attachments_delete_own on public.remote_session_attachments for delete
  using (user_id = auth.uid());

alter table public.remote_commands drop constraint if exists remote_commands_type_check;
alter table public.remote_commands add constraint remote_commands_type_check check (type = any (array[
  'user_message', 'approval_response', 'set_model', 'set_approval_mode', 'request_diff', 'start_preview',
  'stop_preview', 'run_command', 'stop_command', 'list_folders', 'create_folder', 'create_session',
  'stop_generation', 'resume_turn', 'request_keys', 'request_detail', 'request_history',
  'rename_session', 'archive_session', 'delete_session'
]::text[]));

do $$ begin
  alter publication supabase_realtime add table public.remote_session_attachments;
exception when duplicate_object then null; when undefined_object then null;
end $$;
