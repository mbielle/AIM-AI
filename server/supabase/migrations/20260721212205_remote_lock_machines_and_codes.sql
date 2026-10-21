-- Durcissement remote — Phase 3 FINALE : plus AUCUNE écriture directe sur les
-- machines et les codes d'appairage. Ferme le dernier contournement : un compte
-- volé pouvait encore INSÉRER directement un code d'appairage (dont il connaît
-- le clair) puis s'appairer via remote_pair_device.
--
-- Après ce verrou, les SEULS chemins d'écriture sont les fonctions SECURITY
-- DEFINER (propriétaire postgres, qui contourne la RLS) :
--   remote_register_machine / remote_create_pairing_code (exigent le secret
--   machine) et remote_pair_device (consomme le code, côté serveur).
-- La 1.0.89 n'écrit plus jamais ces tables en direct. Seule une 1.0.88 encore
-- ouverte perdrait son heartbeat jusqu'à son redémarrage (auto-update).
--
-- Méthode ALTER POLICY (WITH CHECK false) — réversible en remettant
-- WITH CHECK (user_id = auth.uid()).

alter policy "remote_machines_insert_own" on public.remote_machines
  with check (false);
alter policy "remote_machines_update_own" on public.remote_machines
  with check (false);
alter policy "remote_pairing_codes_insert_own" on public.remote_pairing_codes
  with check (false);
alter policy "remote_pairing_codes_update_own" on public.remote_pairing_codes
  with check (false);