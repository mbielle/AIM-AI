-- Protocole Remote v2 — R2c
-- Toute transition d'une commande passe désormais par remote_update_command,
-- qui impose le secret machine et les transitions d'état vers l'avant.
drop policy if exists remote_commands_update_own
  on public.remote_commands;
