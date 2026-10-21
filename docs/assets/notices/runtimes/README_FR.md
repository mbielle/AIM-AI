# Provenance des runtimes préparés — 20 octobre 2026

[Inventaire versionné des sources et empreintes](PROVENANCE_2026-10-20.json) et [rapport de qualification](../../../qa/RUNTIMES_NOTICES_2026-10-20_FR.md).

Node22.23.3 macOS arm64 provient de l’[archive officielle](https://nodejs.org/dist/v22.23.3/), avec sa LICENSE complète. Les SHASUMS ont été vérifiés via HTTPS ; leur signature est conservée mais non authentifiée indépendamment. Cette limite reste explicite. pnpm10.11.0 est un outil de préparation local, non embarqué dans l’app.

MCP0.0.82 et Playwright/Core1.64.0-alpha-1789764292000 suivent le lock existant. Sept textes LICENSE/NOTICE/ThirdPartyNotices sont conservés et copiés avec les ressources avant signature. Aucun navigateur n’a été téléchargé.

Le moteur MLX neuf provient des 12 révisions du lock du projet ; 26 enregistrements de notices couvrent les sources retenues et sous-composants Cmlx. Les textes intégraux et originaux restent dans les entrées privées de préparation puis dans le produit moteur, avec manifeste relu. Le présent index contient leur provenance et leurs empreintes ; il ne remplace pas les textes à distribuer. Les modèles et leurs poids ont des droits distincts.

Les notices courtes sont conservées byte-identiques ; leur enregistrement dérivé peut les joindre à la licence complète du projet pour le validateur. Ne pas appliquer les métadonnées actuelles à un ancien moteur compilé.

Les dossiers générés et les reçus avec chemins locaux restent privés sous `build/qa-runtime-notices-20261020/`. La copie d’app et les signatures Developer ID, Gatekeeper, la notarisation et la compatibilité minimale seront vérifiées sur le candidat exact. Aucun binaire ne doit être publié sur la seule base de cet index.
