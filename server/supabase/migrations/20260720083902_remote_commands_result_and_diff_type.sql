-- Mode remote — round B2 (Diff à distance). Additif et réversible.
--
-- 1) Les commandes peuvent désormais RAPPORTER quelque chose : colonne `result`
--    (jsonb, nullable). L'ordinateur y dépose la réponse (ici le diff) avant de
--    passer la commande en 'done' ; le téléphone la lit sur SA propre ligne.
--    Générique : servira aussi aux outils suivants (navigateur, terminal).
-- 2) Nouveau type de commande `request_diff`.
--
-- La colonne est nullable et sans défaut : aucune ligne existante n'est touchée.
-- Le CHECK est seulement ÉLARGI (tous les types déjà acceptés le restent), donc
-- aucune ligne existante ne peut le violer.

alter table public.remote_commands
  add column if not exists result jsonb;

alter table public.remote_commands
  drop constraint if exists remote_commands_type_check;

alter table public.remote_commands
  add constraint remote_commands_type_check
  check (type in ('user_message', 'approval_response', 'set_model', 'set_approval_mode', 'request_diff'));