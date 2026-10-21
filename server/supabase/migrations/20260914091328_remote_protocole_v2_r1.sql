-- Télécommande R1 (2026-09-14) : ce que l'app de bureau montre, le téléphone aussi.
-- Strictement ADDITIF : colonnes nullables ou à défaut, un type de commande en plus.

alter table public.remote_sessions
  add column if not exists agent_system text,
  add column if not exists phase text,
  add column if not exists silence boolean not null default false,
  add column if not exists interrupted boolean not null default false,
  add column if not exists run_started_at timestamptz;

alter table public.remote_messages
  add column if not exists reasoning text,
  add column if not exists run_stats jsonb;

alter table public.remote_commands
  drop constraint if exists remote_commands_type_check,
  add constraint remote_commands_type_check check (type = any (array[
    'user_message', 'approval_response', 'set_model', 'set_approval_mode', 'request_diff',
    'start_preview', 'stop_preview', 'run_command', 'stop_command', 'list_folders',
    'create_folder', 'create_session', 'stop_generation', 'resume_turn'
  ]::text[]));
