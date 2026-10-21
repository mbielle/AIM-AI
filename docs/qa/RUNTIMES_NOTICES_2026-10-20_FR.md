# Runtimes et notices — synthèse publique

> **Adaptation publique de l’export alpha, 21 octobre 2026.** Ce texte est dérivé du dossier de travail ; il ne reproduit pas les preuves opérationnelles privées. Les résultats historiques gardent leur portée et ne valent pas validation du candidat ou autorisation de publication.

Le lot runtimes/notices est terminé dans son périmètre de préparation. Les composants réellement préparés sont Node 22.23.3 macOS arm64, Playwright MCP 0.0.82 avec son graphe verrouillé, et un moteur MLX compilé aux 12 pins exacts. Les archives, notices complètes, originaux et dépendances ont été inventoriés avant assemblage du candidat. Les poids de modèles sont exclus.

La vérification Node contre les SHASUMS HTTPS ne vaut pas authentification de leur signature par une clé de release. La signature ultérieure du candidat peut changer les octets exécutables ; un inventaire avant signature ne remplace pas celui de l’artefact distribué. Les reçus privés ne sont pas inclus ici. Les notices publiques et leur [provenance](../assets/notices/runtimes/README_FR.md), les notices de ressources des apps et [THIRD_PARTY_NOTICES](../../THIRD_PARTY_NOTICES.md) sont conservées byte-identiques. Ces obligations ne sont pas remplacées par la licence MIT d’AIM.
