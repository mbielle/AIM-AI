-- Arrêt à distance de la génération en cours.
--
-- Le téléphone demande à l'ordinateur d'interrompre le tour : flux du modèle,
-- sous-agents et processus shell lancés par l'agent. C'est l'équivalent exact du
-- carré noir de la barre de chat du bureau, qui appelle déjà `stop()`.
--
-- Additif et réversible : on ne fait qu'ajouter une valeur à la liste des types
-- de commandes autorisés. Aucune donnée existante n'est touchée, et l'ancienne
-- contrainte se remet en retirant 'stop_generation' de la liste.
--
-- La commande passe par `remote_send_command`, donc elle reste soumise à
-- l'appairage de l'appareil : un compte volé sans le secret machine ne peut pas
-- interrompre le travail de l'ordinateur.

alter table public.remote_commands
  drop constraint if exists remote_commands_type_check;

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
    'create_session',
    'stop_generation'
  ]));
