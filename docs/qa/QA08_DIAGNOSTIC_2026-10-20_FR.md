# QA08 — état public

> **Adaptation publique de l’export alpha, 21 octobre 2026.** Ce texte est dérivé du dossier de travail ; il ne reproduit pas les preuves opérationnelles privées. Les résultats historiques gardent leur portée et ne valent pas validation du candidat ou autorisation de publication.

L’intermittence initiale de démarrage LAN QA08 reste ouverte, cause non établie. Les comparaisons réussies sans reproduction du timeout ne démontrent pas sa correction.

Le défaut connexe QA14 d’annulation d’une ouverture LAN a été reproduit et corrigé : annulation transmise à Network.framework, reprise terminale unique et contrôle d’annulation après reprise. Les régressions et pilotes isolés réussis restent distincts du défaut QA08 et des essais physiques. Aucun succès Internet/TURN ni statut propriétaire supplémentaire n’est inféré. Les détails de reçus/session restent privés. Voir [suivi](SUIVI_71_CONTROLES_2026-10-19_FR.md).
