# AIM continuity — public implementation status

> **Adaptation publique de l’export alpha, 21 octobre 2026.** Ce texte est dérivé du dossier de travail ; il ne reproduit pas les preuves opérationnelles privées. Les résultats historiques gardent leur portée et ne valent pas validation du candidat ou autorisation de publication.

Première alpha Mac Apple Silicon : candidat58 revu par le propriétaire, corrections visuelles du59 demandées et publication GitHub autorisée après vérification. Le jalon7 porte sur la publication et ses preuves extérieures. La campagne exhaustive et le compte QA sont abandonnés pour cette alpha. macOS 14, Remote/iPhone et réseaux non exercés restent sans preuve nouvelle ; les 71 états historiques ne sont pas promus et ne sont plus un seuil préalable de cette alpha. Les 45 états documentaires ouverts des logos sont conservés, sans nouvelle campagne. Aucun essai abandonné ne devient une réussite.

The current Mac sources include the durable agent runtime, local/Remote routing, scoped credentials, budget controls, project persistence and update presentation. Historical software tests and isolated pilots do not prove a real-device update or provider call.

The first Mac alpha includes strict ChatGPT issued-client and ID-token validation. Synthetic offline tests exercise signature, issuer, audience, expiry, nonce, account identity and permission handling. Identity-only sign-ins retain their validated account without enabling inference. Legacy unverified sessions remain stored and require an explicit new registration before reuse. No real authentication or inference is performed by preparation.

See [the final alpha dossier](../../../docs/qa/FINALISATION_ALPHA_2026-10-21_FR.md), [the alpha decision](../../../docs/qa/DECISION_ALPHA_ET_CHEMIN_PUBLICATION_2026-10-21_FR.md) and [the full historical register](../../../docs/VALIDATION_AVANT_PUBLICATION_FR.md).
