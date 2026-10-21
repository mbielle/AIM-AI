-- Chat relayé par l'ordinateur (BYOK, protocole remote v2 §6.13).
-- Les conversations Chat de l'app de bureau sont miroitées comme Code et Agent :
-- la contrainte du mode accepte désormais « chat ». Changement additif, réversible.
alter table public.remote_sessions drop constraint if exists remote_sessions_mode_check;
alter table public.remote_sessions add constraint remote_sessions_mode_check
  check (mode = any (array['code'::text, 'agent'::text, 'chat'::text]));
