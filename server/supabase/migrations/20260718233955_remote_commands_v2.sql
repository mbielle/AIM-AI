-- Mode remote V1.1 : commandes de contrôle (changer modèle / autorisations
-- depuis le téléphone) + mode d'autorisation courant dans le miroir.
-- Additif/réversible : extension du CHECK + colonne nullable.
alter table public.remote_commands drop constraint remote_commands_type_check;
alter table public.remote_commands add constraint remote_commands_type_check
  check (type in ('user_message','approval_response','set_model','set_approval_mode'));

alter table public.remote_sessions add column if not exists approval_mode text;