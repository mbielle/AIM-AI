# AIM — registre historique de qualification complète

> **Décision spécifique du 21 octobre 2026 pour la première alpha Mac.** La [décision alpha](qa/DECISION_ALPHA_ET_CHEMIN_PUBLICATION_2026-10-21_FR.md) remplace le seuil exhaustif ci-dessous pour cette livraison seulement. Les campagnes reportées et le compte QA sont abandonnés pour l’alpha. Les mentions historiques de publication bloquée et d’actions à reprendre ci-dessous décrivent le seuil complet ; elles ne demandent pas de relancer ces campagnes avant cette alpha. Tous les états et résultats historiques sont conservés sans promotion. La revue propriétaire et son accord final restent requis.

## Corrections et reprise — 19 octobre 2026, après la campagne

Voir [le nouveau rapport](qa/CORRECTIONS_2026-10-19_FR.md) et [les 71 suivis détaillés](qa/SUIVI_71_CONTROLES_2026-10-19_FR.md). Les échecs initiaux ci-dessous restent historiques. Aucun contrôle physique supplémentaire n’est clos : D01/D02/D04/L01/L03 restent les cinq acquis. Les tests sources, le pilote QA et les binaires physiques 55 sont séparés. Publication toujours bloquée, dont 60 décisions de droits et revue finale.


## Campagne QA exécutée — 19 octobre 2026

Rapport et anomalies : [CAMPAGNE_TESTS_2026-10-19_FR](qa/CAMPAGNE_TESTS_2026-10-19_FR.md), base structurée `docs/qa/anomalies-2026-10-19.json`. Tests/diagnostic seulement, sans correction produit, nouvel appel payant ni publication.

D01 : À propos Mac 0.1.0 (55) observé et app iPhone 2.0 (55) relevée via inventaire Apple ; identités des apps existantes inchangées, preuves de signature/droits de l’installation 55 conservées. D04 : dix cycles physiques scanner et accueil/retour réussis sur iPhone 55, paire conservée ; le propriétaire confirme ensuite la disparition de l’indicateur système caméra. Preuves : `build/qa-audit-20261019/physical-observations.json`, `physical-harness/scanner-result.xcresult`, rapport ci-dessus. Ces contrôles sont validés dans cette portée ; l’ancien gel 52 demeure historique.

Core complet et plusieurs binaires Mac passent ; la suite Mac complète reste incomplète à cause des tests image (fixture de clé obsolète et attente infinie). Pilote isolé non accepté : empaquetage Sparkle puis confirmation/appairage non établi. Les sondes natives de support réussissent ensuite, mais les deux échecs initiaux demeurent une intermittence non expliquée. Aucun succès logiciel ne clôt les autres contrôles physiques.

P02 est en échec local : quatre chemins personnels et deux assets de skill non inventoriés. P03 reste à préparer : 60 décisions de droits historiques, deux assets supplémentaires à inventorier et notices des bibliothèques natives à vérifier. Tous les autres prérequis et la revue finale sont conservés ; publication bloquée.

## Retour propriétaire sur le build 55 — 19 octobre 2026

Après les consignes T01/T12 (réouverture/conservation, limite 10 $ Estimated,
réponse Anthropic sur Mac puis depuis iPhone ciblant Mac, présentation), le
propriétaire indique : « C'est bon, tout s'est parfaitement bien déroulé. »
Le parcours nominal est donc déclaré réussi sur Mac/iPhone 55, budget actif.
Ce retour est une preuve déclarative propriétaire, sans nouvelles captures,
identifiants fournisseur ou reçus joints ; il ne prouve pas chaque sous-contrôle.

D02 reste vérifié par comparaison avant ouverture : 146 fichiers Mac et 34 iPhone.
D03 et I03/I04 sont partiels : conservation/réponses déclarées, mais revue exhaustive,
reçus, coûts et unicité de la génération restent à rapprocher. I08 n'est plus
bloqué sur le seul petit appel estimatif, mais reste partiel pour les refus de
budget insuffisant, le mode strict, les anciens coûts inconnus et le comptage.
Le constat d'échec Mac 54 est conservé dans l'historique. Ne pas refaire le QR ni
réinstaller les apps pour répéter ces réussites nominales.

Prochain travail : audit du registre des 71 contrôles avec le lanceur QA, pilote
app→app isolé (trois passages + incident catalogue), puis T13/T14 et contrôles
manquants selon prérequis. Aucun essai Internet/TURN ni acceptation de publication
n'est déduit de ce retour. Les sections « avant première ouverture » ci-dessous
sont des preuves historiques antérieures à ce retour.

## Build 55 installé sur Mac et iPhone — 19 octobre 2026

Après accord explicite du propriétaire et vérification que les deux apps étaient
arrêtées, les candidats signés 55 ont été installés sur les deux appareils avec
les mêmes identifiants et droits au trousseau. Les copies ciblées et comparaisons
après remplacement, **avant première ouverture**, vérifient 146 fichiers persistants
Mac et 34 fichiers iPhone (sept répertoires). Le journal Remote Mac est inclus ;
les clés n'ont été ni lues ni exportées. L'inventaire de l'app officielle iPhone
est inchangé. Copies privées et retours arrière sont conservés.

Une interruption CoreDevice a arrêté la première copie iPhone avant remplacement.
L'état Apple indiquait toujours l'iPhone déverrouillé ; la reprise unique a terminé
la copie avec comparaison indépendante d'Application Support, puis les sept
répertoires ont été comparés après installation. Aucun effacement ni réappairage.

Les apps 55 ne sont pas encore ouvertes : migration, conservation observée après
ouverture, reconnexion et appel réel avec budget actif restent à qualifier. Les
61 tests Mac et trois UI simulateur déjà réussis ne valident pas ces essais physiques.
Reprendre par conservation, puis T12 avec **limite 10 $ / Estimated activée** ;
contrôler statut/Arrêter, échange en haut et indicateur unique côté iPhone. Ensuite
T13. Autorisation inchangée : 10 $ cumulés Anthropic/OpenRouter, essais précédents
compris. Les constats 54/53 plus bas sont historiques ; publication toujours bloquée.

Décision du propriétaire, 18 octobre 2026 : **ne pas publier le dépôt, le site ni
les téléchargements tant que tous les contrôles obligatoires de ce fichier ne
sont pas validés.** Ce document organise la qualification ; il ne déclare pas
l'application prête.

## Historique Mac 54/iPhone 53 : réponse réussie après désactivation du budget

Les permissions sans nouveau QR sont confirmées par le propriétaire (L03). Les
réponses API Mac et iPhone ciblant Mac sont reçues (I03/I04 partiels), mais le budget
Mac estimatif a échoué sur la mémoire Anthropic. Le propriétaire l'a désactivé pour
finir : I08 reste donc bloqué jusqu'au nouvel essai sur 55, limite active. Plafond
commun autorisé : 10 $ cumulés Anthropic/OpenRouter, essais précédents compris.
61 tests Mac et trois parcours UI simulateur passent sur les correctifs 55 ; candidats
signés séparés puis installés ; conservation avant ouverture vérifiée. Cela ne remplace ni les coûts/réceptions réels, ni la
revue visuelle complète, ni Internet direct/TURN.

## Règle de passage

Exécuter les lots dans l'ordre ci-dessous. Un lot suivant peut être préparé,
mais son essai réel attend ses prérequis. Toute anomalie bloque le contrôle
concerné jusqu'à correction et nouvel essai. Ne pas effacer un échec antérieur.

Un contrôle est **VALIDÉ** seulement avec une preuve sur le candidat concerné :
date, build iPhone/Mac, profil et réseau de test, action, résultat attendu et
observé, référence de capture ou journal expurgé. Un test automatisé et un essai
sur appareil sont deux preuves distinctes. Le code compilé, une connexion verte
ou une réponse synthétique ne valident pas un vrai appel IA.

Statuts : **VALIDÉ**, **À TESTER**, **À PRÉPARER**, **ÉCHEC**. Tous les contrôles
sont obligatoires pour le périmètre annoncé. Une fonction ne peut devenir
« non applicable » que par une décision explicite du propriétaire, documentée
avec son retrait des interfaces et promesses publiques. Les contrôles de données,
d'accès, de budget, de licences et de reproductibilité ne sont pas dispensables.

Après une correction, refaire le contrôle en échec et les régressions touchées.
Les preuves d'un ancien build restent historiques : documenter pourquoi elles
restent applicables ou refaire l'essai. Exécuter la régression finale sur les
binaires exacts proposés au téléchargement.

**État actuel : publication bloquée.** Mac 55 et iPhone 55 installés, données
persistantes comparées avant ouverture. Réouverture et petits appels avec budget actif
déclarés réussis sur 55 ; coûts/reçus, refus de budget et Internet/relais restent à qualifier. Les résultats 54/53 ci-dessus
et plus bas restent historiques. Le [parcours propriétaire](PARCOURS_TESTS_PROPRIETAIRE_FR.md)
donne les scénarios et prérequis des 71 contrôles.

## Coûts, données et environnement

- Conserver les applications officielles. Copier les données AIM avant chaque
  remplacement de candidat, y compris le journal Remote Mac, et garder un retour
  arrière. Ne pas exporter les clés du trousseau dans les preuves.
- Utiliser un projet/dossier de qualification et des commandes inoffensives.
  Aucun accès au terminal ou aux applications personnelles pour un simple essai
  de transport.
- API autorisées : **Anthropic / Sonnet ou Haiku 5.5 et OpenRouter / GLM 5.3,
  plafond commun total de 10 $ pour les tests**.
  Ce plafond comprend les essais déjà effectués : relever le consommé réel et le
  solde avant de poursuivre. Le budget mensuel configuré dans AIM n'est pas un
  nouveau crédit de test. Ne pas changer de fournisseur ni utiliser une clé
  Exa/Brave sans configuration personnelle et autorisation de coût correspondante.
- Commencer par un modèle déjà disponible localement si possible. Un appel
  OpenRouter depuis le Mac nécessite Internet ; le transport LAN sans Internet
  se teste avec une opération locale ou un modèle réellement local.
- Hébergement public : plafond initial **20 €/mois**, aucun dépassement payant
  automatique ; aucun achat/activation avant devis concret et accord.
- Changer de transport ne doit pas modifier silencieusement l'appareil exécutant
  la demande ou son fournisseur. Toujours relever la route réellement utilisée.

## 1. Candidat, conservation et interface

| ID | Contrôle et résultat attendu | Statut |
|---|---|---|
| D01 | Installer iPhone et Mac avec les mêmes identifiants et droits signés ; vérifier les versions réellement installées. | VALIDÉ — 19 octobre, Mac À propos 0.1.0 (55), iPhone inventaire 2.0 (55), identités inchangées ; preuves de signature/droits 55 conservées ; campagne QA |
| D02 | Copies ciblées vérifiées, puis comparaison avant première ouverture : données persistantes identiques, app officielle inchangée. | VALIDÉ — builds 55 : 146 fichiers Mac et 34 fichiers iPhone comparés avant ouverture le 19/10 ; retours arrière conservés |
| D03 | Après réouverture sur les deux appareils : projets, conversations, documents, instructions, réglages, clés utilisables et appairages conservés. | PARTIEL — propriétaire : réouverture/conservation et parcours nominal 55 réussis le 19/10 ; revue exhaustive finale et clés locales iPhone restent à qualifier |
| D04 | Ouvrir/fermer le scanner dix fois sur l'iPhone physique, dont fermeture immédiate et passage en arrière-plan : aucune pause prolongée, relance ni caméra restant active. | VALIDÉ — 19 octobre, iPhone 55 : dix cycles + accueil/retour, paire inchangée ; indicateur caméra disparu confirmé propriétaire ; ancien gel 52 conservé dans l’historique |
| D05 | Nom/carte du Mac cliquable ; reconnexion après relance ; déconnexion volontaire respectée ; plusieurs Macs sans choix arbitraire ; « Cet iPhone » reste un choix explicite d'exécution. | PARTIEL — 55 : reconnexion/opt-out et quatre modèles acquis ; persistance de cible décidée et corrigée en sources/unitaires ; nouveau candidat physique et multi-Mac/parité complète ouverts |
| D06 | Revue iPhone : clavier ouvert/fermé, streaming rapide, défilement manuel/automatique, rotation et petites/grandes polices sans chevauchement. | À TESTER |
| D07 | Revue Mac : fenêtre petite/grande, clair/sombre, navigation clavier, VoiceOver, QR et éditeur des droits défilants sans action inaccessible. | À TESTER ; About/Remote et ouverture des droits observés en 52 |
| D08 | Sélection de modèles et onglets : un appui normal fonctionne ; aucun appui prolongé requis. Navigation projet → conversation → retour cohérente. | À TESTER |
| D09 | Copie explicite de profil, import/export et changement de profil : aperçu, confirmation, erreurs récupérables, aucune fuite de clés ou de données entre profils. | À TESTER |

## 2. Liaison locale et autorisations, sans appel payant

Préconditions : Mac éveillé, apps ouvertes, même Wi-Fi non invité. Réutiliser la
paire existante pour les premiers essais. Les essais QR destructifs utilisent
ensuite une paire ou un profil de qualification distinct.

| ID | Contrôle et résultat attendu | Statut |
|---|---|---|
| L01 | La paire existante se connecte sans nouveau QR et l'état de connexion devient direct. | VALIDÉ — build 52, capture propriétaire du 18/10 |
| L02 | Lire depuis l'iPhone une conversation/activité connue du Mac ; contenu exact, bon profil, aucun appel modèle. Une connexion verte seule ne suffit pas. | PARTIEL — 55 : témoin existant lisible et quatre modèles Anthropic présents ; pilote QA synthétique catalogue/lecture validé ; parité exhaustive physique des routes/capacités/bibliothèque reste ouverte |
| L03 | Désactiver « Use terminal » dans Permissions sur Mac, enregistrer : reconnexion sans QR et nouveaux droits visibles sur iPhone. Restaurer ensuite par action explicite et vérifier. | VALIDÉ PAR LE PROPRIÉTAIRE le 19 octobre, Mac 54/iPhone 53 : droits mis à jour sans QR ; ne valide pas L04/L05 |
| L04 | Essayer une opération retirée : refus côté Mac, aucun effet ; lire reste possible. Vérifier également le refus d'une ancienne session/commande mise en cache. | À TESTER sur appareils ; régressions natives synthétiques disponibles |
| L05 | Couper l'accès iPhone global sur Mac puis le réactiver : refus puis reprise cohérents, données préservées. | À TESTER |
| L06 | Révoquer la paire de qualification : session coupée, reconnexion et anciens messages refusés. Une nouvelle association exige un nouvel accord Mac. | À TESTER |
| L07 | QR expiré, déjà consommé, invalide ou destiné à un autre appareil : refus propre ; annuler l'association ne laisse aucun accès actif. | À TESTER |
| L08 | Appareil non appairé, mauvais profil et identité modifiée : accès refusé, sans faux compte cloud. | À TESTER |
| L09 | Même réseau local sans accès Internet : découverte, authentification et lecture locale fonctionnent sans service AIM public ni Supabase. | À TESTER |
| L10 | Réseau local refusé dans iOS/macOS ou Wi-Fi invité isolant les clients : erreur compréhensible, pas de blocage UI ; récupération après autorisation/réseau corrigé. | À TESTER |

## 3. Vrais appels IA et vérification du lieu d'exécution

Commencer par une seule demande courte. Exemple : « Réponds exactement
REMOTE-OK-01 ». Relever le modèle, le fournisseur, l'appareil exécutant et
l'identifiant de tâche. Aucun test payant tant que le solde autorisé n'est pas
vérifié. Si aucun modèle local compatible n'est disponible, préparer ce parcours
séparément ; ne pas appeler un modèle cloud en le présentant comme local.

| ID | Contrôle et résultat attendu | Statut |
|---|---|---|
| I01 | Modèle local sur Mac, lancé directement sur Mac : réponse correcte sans accès fournisseur, modèle/serveur identifiés. | À PRÉPARER selon modèle installé |
| I02 | Même modèle local lancé depuis iPhone en ciblant explicitement le Mac : requête reçue/exécutée sur Mac, réponse et streaming sur iPhone ; aucun appel local iPhone substitué. | À TESTER après I01 et L02 |
| I03 | API autorisée directement sur Mac : réponse courte correcte, usage/coût et reçu fournisseur vérifiables. | PARTIEL — propriétaire : appel Anthropic Mac 55 réussi avec limite 10 $ Estimated active ; reçu et coût réel à rapprocher |
| I04 | API autorisée lancée depuis iPhone avec cible Mac : même route Mac, clé utilisée sur Mac, réponse retournée ; pas de deuxième génération facturée. | PARTIEL — propriétaire : appel depuis iPhone 55 ciblant Mac 55 réussi avec limite active ; route, activité fournisseur et absence de doublon à rapprocher |
| I05 | Choisir « Cet iPhone » : exécution locale iPhone explicite, association Mac conservée et retour vers Mac possible. | À TESTER |
| I06 | Annuler une réponse depuis iPhone : production arrêtée sur Mac, état cohérent, usage partiel conservé. Double appui Envoyer et réponse réseau perdue : une seule commande/charge logique. | À TESTER |
| I07 | Erreur fournisseur, clé absente/invalide, modèle indisponible, limite de contexte : erreur utile, brouillon conservé, pas de basculement facturé automatique. | À TESTER avec compte/configuration de qualification |
| I08 | Budget actif (10 $ pour la reprise autorisée du 19 octobre ; 5 $ historique) : petit appel admis ; budget restant insuffisant et protection stricte refusent correctement ; historique inconnu expliqué sans fausse gratuité. Compter les frais connus une seule fois sur Mac/iPhone. | PARTIEL — propriétaire : petits appels 55 admis avec limite 10 $ Estimated active ; refus insuffisant/strict, anciens coûts inconnus et comptage restent à tester. Échec Mac 54 conservé en historique ; iPhone 5 $ historique réussi en 50 |
| I09 | Sources projet et instructions : code témoin trouvé, nom du fichier lisible, sources exclues non utilisées ; profils/projets isolés ; import/renommage/brouillons conservés. | À TESTER sur les deux appareils ; preuves iPhone anciennes à requalifier |
| I10 | Recherche OpenRouter : vrais liens vérifiables, distinction résultats/citations/visites, activité honnête, une durée globale, réflexion repliée, arrêt et budget cohérents. | À TESTER sur les deux appareils |
| I11 | Recherche AIM Exa puis Brave : clé personnelle, limites/recherche/lecture/annulation, outils hébergés désactivés, frais sans doublon ; comparaison à questions identiques sans promesse prématurée de qualité/prix. | À PRÉPARER — coûts et clés distincts à autoriser |
| I12 | Logos : CDN déclaré, SVG pris en charge, image invalide/refus/délai, confidentialité et cache ; globe de remplacement, aucun annuaire externe. | À TESTER |

## 4. Coupures, reprise et persistance des tâches

| ID | Contrôle et résultat attendu | Statut |
|---|---|---|
| R01 | Fermer l'app iPhone pendant une tâche Mac : le Mac continue ; réouverture retrouve la même tâche et son résultat, sans réexécution. | À TESTER avec tâche de qualification |
| R02 | Wi-Fi iPhone coupé/rétabli et perte brève du réseau Mac : état reconnexion puis récupération, sans doublon ni approbation perdue. | À TESTER |
| R03 | Verrouiller l'iPhone puis revenir : session restaurée selon l'intention ; une déconnexion volontaire reste déconnectée. | PARTIEL — 55 : relance/reconnexion et déconnexion volontaire persistante acquises ; verrouillage/retour physique reste distinct |
| R04 | Mac verrouillé, en veille, puis réveillé : disponibilité affichée honnêtement ; aucune action UI pendant un verrouillage qui l'interdit. Reprise sûre après réveil. | À TESTER |
| R05 | Quitter/redémarrer AIM Mac et redémarrer les appareils : journaux et tâches durables récupérés ; commande incertaine non exécutée deux fois. | À TESTER |
| R06 | Révoquer/changer les droits pendant une coupure ou une action en attente : ancien droit invalidé avant reprise, résultat tardif sans effet non autorisé. | À TESTER |
| R07 | Pièce jointe autorisée, taille limite dépassée et transfert interrompu : intégrité, limites, nettoyage et reprise sans fuite entre paires. | À TESTER |

## 5. Hors domicile : Internet direct et relais réel

Préparer d'abord le service de coordination TLS et TURN de qualification, ses
certificats et ses limites. Il n'existe aucun succès hors domicile déduit du test
sur le même Wi-Fi. Couper le Wi-Fi iPhone et relever effectivement 4G/5G ; laisser
le Mac sur son réseau habituel. Le test doit se faire dans les apps natives.

| ID | Contrôle et résultat attendu | Statut |
|---|---|---|
| N01 | Service autonome de coordination WSS et coturn installables, TLS valide, secrets hors dépôt, identifiants TURN temporaires et quotas actifs. | À PRÉPARER — hébergement à chiffrer/autoriser |
| N02 | iPhone en 4G/5G, Mac en Wi-Fi : appareil appairé retrouvé, lecture puis vraie demande IA et réponse. Aucun réseau local partagé. | À TESTER après N01 et lot 3 |
| N03 | Route réellement directe Internet démontrée par la paire ICE sélectionnée/diagnostic transport ; libellé cohérent. | À TESTER |
| N04 | Forcer TURN : allocation réelle, transport indiqué relayé, commande/réponse chiffrées de bout en bout ; serveur/relais sans clés de commandes. | À TESTER — un test loopback ne suffit pas |
| N05 | Passer Wi-Fi → mobile → Wi-Fi pendant une tâche : reprise du même identifiant, résultat complet et un seul effet. | À TESTER |
| N06 | Bloquer UDP puis tester un réseau restrictif : direct si possible, relais compatible sinon, erreur utile si aucun chemin ; pas de boucle infinie. | À TESTER |
| N07 | Coordination ou TURN indisponible, certificat invalide, quota épuisé : refus explicite ; direct local disponible préservé ; aucun dépassement payant automatique. | À TESTER |
| N08 | Installation personnelle du service : configuration dans AIM, nouvelle association et mêmes parcours lecture/IA/reprise ; aucun compte Supabase obligatoire. | À TESTER |
| N09 | Mesures de trafic, expiration et révocation des allocations, limites par appareil, alertes et coût forfaitaire ≤20 €/mois démontrés. | À PRÉPARER puis TESTER |

## 6. Autres fonctions annoncées et sécurité intégrée

| ID | Contrôle et résultat attendu | Statut |
|---|---|---|
| F01 | Chat, Code et Agent : création, résultat, erreur, annulation, reprise ; bon modèle et bonne cible sur Mac/iPhone. Les opérations sensibles demandent l'approbation prévue. | À TESTER |
| F02 | Outil terminal dans un dossier temporaire : commande inoffensive approuvée, refus sans accord, annulation et limites d'exécution effectives. | À TESTER après droits/approbations |
| F03 | Computer use/navigateur : observation fraîche, bonne fenêtre, priorité utilisateur, refus quand verrouillé/non autorisé ; aucun résultat inventé. | À TESTER avec pages/apps de qualification |
| F04 | Connecteurs et skills : configuration, action approuvée, erreur, révocation, mode privé ; contenu tiers traité comme données, secrets absents des journaux. | À TESTER |
| F05 | Voix, dictée et médias si exposés : consentement, démarrage/arrêt, erreur, interruption, données et coûts ; absence d'enregistrement/transport inattendu. | À TESTER |
| F06 | Synchronisation et imports explicites : comptes/profils distincts, conflit, hors ligne, suppression/révocation et reprise ; aucun mélange local/cloud implicite. | À TESTER |
| F07 | Remote Supabase auto-hébergé : authentification, appareil/compte/profil corrects, commande chiffrée, approbation et révocation ; appairages existants préservés. | À TESTER |
| F08 | Injection de contenu dans page/document/résultat outil : aucune permission, clé ou commande sensible accordée par le contenu seul. | À TESTER |
| F09 | URL privée/loopback, redirection vers réseau interdit, image/page trop grosse ou malformée, SVG actif/ressource distante : protections réseau/décodage effectives. | À TESTER avec fixtures isolées |
| F10 | Rejeu, ordre inversé, mauvais expéditeur, ancienne révision, mauvais profil, enveloppe altérée : refus côté exécutant, aucune action répétée. | À TESTER ; preuves synthétiques à joindre séparément |
| F11 | Mode privé : connexions interdites effectivement arrêtées/refusées, reprise contrôlée ; données conservées. | À TESTER |

## 7. Compilation, distribution, droits et exploitation

| ID | Contrôle et résultat attendu | Statut |
|---|---|---|
| P01 | Checkout neuf sans dossiers locaux privés : instructions Mac/iOS/simulateur exécutables, dépendances et artefacts natifs reproductibles/pinnés. | À TESTER sur le candidat final |
| P02 | CI complète, tests ciblés et audit de publication passent sur le commit exact ; aucun secret, donnée personnelle, sauvegarde, certificat privé ou artefact non prévu. | PARTIEL — corrections : audits locaux publication/inventaire passent, régressions logicielles vérifiées ; 60 droits release encore ouverts et CI sur commit final exact non exécutée |
| P03 | Licences du code et dépendances, notices libdatachannel/coturn et dépendances, sources de modifications à fournir, attributions et droits des assets validés. | À PRÉPARER — 60 droits historiques ouverts ; deux icônes MIT inventoriées ; notices et liste Mac complétées en QA, obligations/composition des distributions finales à revoir |
| P04 | Signature et notarisation de distribution Mac, helper, permissions et installation depuis téléchargement neuf, sans contournement de sécurité. | À TESTER — signature de qualification insuffisante |
| P05 | Vraie mise à jour Mac/Sparkle signée : bon canal, vérification de signature, conservation des données/droits et retour arrière documenté. | À TESTER |
| P06 | Distribution iPhone retenue et mise à jour réelle : signature/profil/canal valides, numéros corrects, données et appairages conservés. | À TESTER — installation de développement ne valide pas le canal public |
| P07 | Service existant : sauvegarde restaurable, migration répétée hors production, retour arrière, fermeture des anciens parcours commerciaux et archive privée de l'ancien web. | À PRÉPARER puis TESTER avec le propriétaire |
| P08 | Guide contributeur et utilisateur : BYOK/local, limites Remote, Mac disponible, budgets approximatifs, service personnel, dépannage et signalement de bugs sans secrets. | À TESTER par une lecture et installation indépendante |
| P09 | Preview landing : vrais téléchargements HTTPS, versions/empreintes/signatures exactes, liens, coordonnées, mentions et promesses correspondant au périmètre qualifié. | À PRÉPARER puis TESTER avant toute publication |
| P10 | Parcours complet depuis installation neuve par une personne autre que le développeur : démarrage, modèle, premier chat, QR, droits, tâche distante et récupération. | À TESTER |

## 8. Régression finale et autorisation de publication

| ID | Contrôle et résultat attendu | Statut |
|---|---|---|
| G01 | Tous les contrôles ci-dessus validés sur le périmètre annoncé, sans anomalie bloquante ni preuve manquante ; changements de build analysés et retestés. | À TESTER |
| G02 | Sur les binaires finaux : réouverture/données, modèle local, API réelle, recherche, LAN, mobile/direct, relais forcé, reprise, droits et révocation repassent. | À TESTER |
| G03 | Revue du dossier de preuves avec le propriétaire puis accord explicite pour publier le dépôt, le site et les applications. Publication effectuée seulement après cet accord. | À PRÉPARER |

## Fiche de preuve à remplir à chaque essai

```text
ID du contrôle :
Date / personne :
Build iPhone / Mac / commit / empreintes des binaires :
Profil de qualification (aucune clé) :
Réseau iPhone / Mac / mode de transport réellement observé :
Modèle / fournisseur / appareil exécutant (si IA) :
Budget de test restant avant / coût connu après / frais inconnus :
Prérequis et action exacte :
Résultat attendu / résultat observé :
Statut : VALIDÉ / ÉCHEC / À TESTER / À PRÉPARER
Preuve expurgée (capture, journal, reçu fournisseur, identifiant non secret) :
Anomalie et contrôle à rejouer après correction :
```

Conserver les preuves privées hors dépôt public, et publier uniquement une
synthèse expurgée. Ne jamais inclure QR actif, clé, empreinte d'appareil personnelle
inutile, conversation privée ou accès à un compte.

## Prochain essai guidé

Utiliser désormais [PARCOURS_TESTS_PROPRIETAIRE_FR.md](PARCOURS_TESTS_PROPRIETAIRE_FR.md)
pour les manipulations complètes et le retour groupé. T01–T06 sont possibles sur
Mac 54/iPhone 53 sans génération ; T07–T10 concernent le Mac 54 installé. Les vrais appels attendent les
prérequis modèle/route/budget ; le mobile/direct et TURN attendent N01. Les 30
vérifications automatisées du 19 octobre sont des preuves séparées, pas des statuts
physiques VALIDÉ ajoutés à ce registre.

### Checkpoint précédent, conservé pour traçabilité

Le propriétaire a confirmé qu'en sélectionnant le Mac lui-même dans le menu du
point vert, un modèle apparaît. Le catalogue complet et la lecture restent à
qualifier. Le build 53 est installé sur les deux appareils ; copie ciblée vérifiée avant
réouverture : 32 fichiers iPhone et 79 Mac inchangés.

**L02 sur le build 53 installé**, sans appel IA : ouvrir le point vert, puis toucher le
nom du Mac dans « Exécuter sur » (et non « Gérer les Mac »). Ouvrir le
sélecteur depuis la barre de saisie ; son sous-titre doit nommer ce Mac. Comparer
« Modèles ajoutés » et « Catalogue complet » avec Mac, fournisseur par fournisseur.
Anthropic reste dans « Online » même si la requête sera exécutée sur Mac ;
« Local · Mac » désigne les moteurs locaux. Modifier un ajout sur Mac, attendre
la publication ou utiliser « Actualiser le catalogue », vérifier sa présence sur
iPhone. Ouvrir une conversation de qualification Mac si disponible et comparer
le contenu. Ne pas recopier la clé Mac sur iPhone pour masquer un échec Remote.
Noter le résultat avant toute génération.

Ensuite L03 : Mac → Réglages AIM → Remote → iPhone → Permissions… → désactiver
« Use terminal » → enregistrer. Sur iPhone, attendre la reconnexion puis ouvrir
Security details : Terminal doit avoir disparu. Relever le résultat, puis
restaurer explicitement ce droit et vérifier le retour. Ne pas révoquer la paire.

Puis I01/I02 si un modèle local est disponible, ou I03/I04 après vérification du
solde API autorisé. N02 n'est lancé qu'après préparation du service N01.

Documents associés : [état d'implémentation](IMPLEMENTATION_STATUS.md),
[Remote direct](DIRECT_REMOTE_FR.md),
[revue visuelle complète](UX_REVIEW_CHECKLIST.md),
[reprise](REPRISE-FR.md).
