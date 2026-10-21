# SourceKit et confinement — portée publique

> **Adaptation publique de l’export alpha, 21 octobre 2026.** Ce texte est dérivé du dossier de travail ; il ne reproduit pas les preuves opérationnelles privées. Les résultats historiques gardent leur portée et ne valent pas validation du candidat ou autorisation de publication.

L’historique protégé conserve un échec réel de SourceKit imbriqué sous la barrière Contacts : `sandbox_apply: Operation not permitted`, puis `SOURCEKITD FATAL ERROR`. Les assertions et la protection ne sont pas affaiblies pour présenter ce passage comme réussi.

Le lot logiciel ultérieur a routé explicitement les deux intégrations SourceKit/confinement vers un exécutable natif obligatoire distinct de la découverte XCTest : 1090 XCTest exécutés, 24 ignorés historiques, zéro échec ; deux cas natifs et 12 vérifications, comptés séparément. Le lanceur termine encore en préparation pour la porte propriétaire. Ces preuves historiques ne sont pas rejouées par l’export et ne valent pas qualification physique ou publication. Voir [autonomie](AUTONOMY_FR.md).
