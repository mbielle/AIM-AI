-- Création de session à distance (round V2) : trois nouveaux types de commande.
-- Additif et réversible : seule la liste autorisée de `type` change.
--   list_folders   : lister les racines autorisées, ou les sous-dossiers d'un chemin autorisé
--   create_folder  : créer un dossier à l'intérieur d'une racine autorisée
--   create_session : créer une session Code/Agent et y envoyer le premier message
-- session_id reste NULL pour ces trois types (colonne déjà nullable, et
-- remote_send_command insère p_session_id sans le valider : rien à changer côté RPC).
alter table public.remote_commands drop constraint if exists remote_commands_type_check;

alter table public.remote_commands
  add constraint remote_commands_type_check
  check (type = any (array[
    'user_message',
    'approval_response',
    'set_model',
    'set_approval_mode',
    'request_diff',
    'start_preview',
    'stop_preview',
    'run_command',
    'stop_command',
    'list_folders',
    'create_folder',
    'create_session'
  ]));
