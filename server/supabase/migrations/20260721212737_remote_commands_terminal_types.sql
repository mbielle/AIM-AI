-- Mode remote — round B4 (terminal à distance). Additif : le CHECK est
-- seulement ÉLARGI (+run_command, +stop_command), aucune ligne existante touchée.

alter table public.remote_commands
  drop constraint if exists remote_commands_type_check;

alter table public.remote_commands
  add constraint remote_commands_type_check
  check (type in (
    'user_message', 'approval_response', 'set_model', 'set_approval_mode',
    'request_diff', 'start_preview', 'stop_preview',
    'run_command', 'stop_command'
  ));