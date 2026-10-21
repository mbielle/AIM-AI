-- Durcissement remote — Phase 3a : fermer la FORGE d'appareils, sans rien casser.
--
-- Un compte volé pouvait encore : (1) insérer directement une ligne dans
-- remote_devices avec un secret de son choix ; (2) écraser via UPDATE le
-- secret_hash d'un appareil légitimement appairé. Les deux donnaient le
-- contrôle de la machine sans accès physique.
--
-- Méthode : ALTER POLICY (pas de REVOKE/DROP). Les policies étant AND-ées avec
-- les droits, WITH CHECK(false) bloque toute écriture directe ; les RPC
-- SECURITY DEFINER (propriétaire postgres) contournent la RLS et continuent.
--
-- ① Plus AUCUNE insertion directe d'appareil (seul remote_pair_device en crée).
alter policy "remote_devices_insert_own" on public.remote_devices
  with check (false);

-- ② UPDATE direct = RÉVOCATION uniquement : la nouvelle ligne doit être révoquée
--    (revoked_at non nul). Écraser secret_hash en gardant l'appareil actif est
--    donc impossible ; « dé-révoquer » aussi. Le bouton ✕ des Réglages (set
--    revoked_at = now()) continue de marcher, la ré-association passe par la
--    RPC (qui remet revoked_at à null en tant que propriétaire).
alter policy "remote_devices_update_own" on public.remote_devices
  with check (user_id = auth.uid() and revoked_at is not null);

-- Rollback : WITH CHECK (user_id = auth.uid()) sur les deux policies.