-- Mode remote — round B3 (navigateur à distance). Additif et réversible.
--
-- Deux nouveaux types de commande : `start_preview` / `stop_preview`. Le CHECK
-- est seulement ÉLARGI (tous les types déjà acceptés le restent), donc aucune
-- ligne existante ne peut le violer. Aucune donnée touchée.

alter table public.remote_commands
  drop constraint if exists remote_commands_type_check;

alter table public.remote_commands
  add constraint remote_commands_type_check
  check (type in (
    'user_message', 'approval_response', 'set_model', 'set_approval_mode',
    'request_diff', 'start_preview', 'stop_preview'
  ));