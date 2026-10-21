-- Mode Remote V1 — fondations (spec docs/superpowers/specs/2026-07-18-remote-mode-design.md)
-- Additif et réversible : 4 nouvelles tables, RLS user-only, Realtime.
-- Rollback : drop table remote_commands, remote_messages, remote_sessions, remote_machines;

-- 1) Machines (un enregistrement par ordinateur, heartbeat 30 s)
create table if not exists public.remote_machines (
  id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null default 'Mon ordinateur',
  platform text,
  app_version text,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

-- 2) Miroir des sessions Code/Agent (fenêtre de 25 messages, non rétroactif)
create table if not exists public.remote_sessions (
  id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  machine_id uuid not null references public.remote_machines(id) on delete cascade,
  mode text not null check (mode in ('code','agent')),
  title text not null default 'Session',
  workspace text,
  model_id text,
  status text not null default 'idle' check (status in ('idle','running','waiting_approval')),
  pending_approval jsonb,
  message_count integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_synced_at timestamptz not null default now()
);
create index if not exists remote_sessions_machine_idx
  on public.remote_sessions (machine_id, updated_at desc);

-- 3) Messages miroir (25 derniers par session, tool calls embarqués)
create table if not exists public.remote_messages (
  id uuid primary key,
  session_id uuid not null references public.remote_sessions(id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  seq bigint not null,
  role text not null check (role in ('user','assistant')),
  content text not null default '',
  tool_calls jsonb,
  model text,
  created_at timestamptz not null default now()
);
create index if not exists remote_messages_session_seq_idx
  on public.remote_messages (session_id, seq);

-- 4) Commandes téléphone → ordinateur (idempotentes par id + status)
create table if not exists public.remote_commands (
  id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  machine_id uuid not null references public.remote_machines(id) on delete cascade,
  session_id uuid references public.remote_sessions(id) on delete set null,
  type text not null check (type in ('user_message','approval_response')),
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'pending' check (status in ('pending','ack','done','error')),
  error text,
  created_at timestamptz not null default now(),
  acked_at timestamptz,
  done_at timestamptz
);
create index if not exists remote_commands_machine_status_idx
  on public.remote_commands (machine_id, status, created_at);

-- RLS : chaque utilisateur ne voit et ne touche QUE ses lignes.
alter table public.remote_machines  enable row level security;
alter table public.remote_sessions  enable row level security;
alter table public.remote_messages  enable row level security;
alter table public.remote_commands  enable row level security;

do $$
declare t text;
begin
  foreach t in array array['remote_machines','remote_sessions','remote_messages','remote_commands'] loop
    execute format('create policy %I on public.%I for select using (user_id = auth.uid())', t || '_select_own', t);
    execute format('create policy %I on public.%I for insert with check (user_id = auth.uid())', t || '_insert_own', t);
    execute format('create policy %I on public.%I for update using (user_id = auth.uid()) with check (user_id = auth.uid())', t || '_update_own', t);
    execute format('create policy %I on public.%I for delete using (user_id = auth.uid())', t || '_delete_own', t);
  end loop;
end $$;

-- Realtime : le téléphone s'abonne aux sessions/messages, l'ordi aux commandes.
alter publication supabase_realtime add table public.remote_machines;
alter publication supabase_realtime add table public.remote_sessions;
alter publication supabase_realtime add table public.remote_messages;
alter publication supabase_realtime add table public.remote_commands;
