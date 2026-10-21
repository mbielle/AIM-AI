# Développer et qualifier AIM avec moins d'interruptions

Le système s'exécute localement, sans nouveau fournisseur IA, abonnement ou
service distant. L'agent Codex conduit la boucle de diagnostic/correction ; les
scripts exécutent les opérations répétitives et conservent les preuves.

## Démarrer au bon endroit

Ouvrir Codex dans le dépôt de transition, et non dans son parent historique :

```sh
cd "$AIM_REPO"
python3 scripts/qa/catalog.py --check
python3 scripts/qa/run.py --suite quick --target software
```

Les skills du projet deviennent disponibles au prochain tour d'une session qui
travaille depuis ce dépôt. Ils sont aussi utilisables explicitement en donnant
leur chemin depuis un chat existant : `aim-verify`, `aim-remote-qa`,
`aim-device-session`, `swift-testing-expert`, `swiftui-pro`, `mobilebuildmcp-cli`.
Les trois skills AIM chargent seulement la procédure utile. Les versions tierces
et leurs empreintes sont consignées dans `tools/apple-qa/provenance.json`.

## Les commandes qui produisent des preuves

| Objectif | Commande à la racine du dépôt |
|---|---|
| Prévisualiser sans lancer | `python3 scripts/qa/run.py --suite quick --dry-run` |
| Régressions Core Remote et isolation QA | `python3 scripts/qa/run.py --suite quick --target software` |
| Régressions Mac ciblées | `python3 scripts/qa/run.py --suite quick --component macos` |
| Tests de support de droits précis | `python3 scripts/qa/run.py --controls L03,L04` |
| Interface iPhone réellement exécutée | `python3 scripts/qa/run.py --suite quick --target simulator` |
| Tests unitaires iPhone (AIMTests, distincts des UI) | `python3 scripts/qa/run.py --target simulator --ios-tests unit` |
| Pilote Mac + iPhone simulateur, trois passages et incident catalogue | `python3 scripts/qa/run.py --suite smoke --target apps` |
| Préparer ce pilote sans lancer de fenêtre Mac | `python3 scripts/qa/run.py --suite smoke --target apps --prepare-only` |
| Sondes natives déjà reconstruites | `python3 scripts/qa/run.py --suite remote --target native --probe /chemin/sonde` |
| Revue de préparation à la release | `python3 scripts/qa/run.py --suite release --target software --component all` |
| Tests du lanceur | `python3 -m unittest discover -s scripts/qa -p 'test_*.py' -v` |

`--controls` sélectionne des tests de support, jamais l'acceptation entière du
contrôle. `release` conserve un blocage explicite pour la revue propriétaire,
les contrôles physiques et les binaires finaux ; cette commande ne publie rien.

Les suites `smoke` et `remote` lancées uniquement en logiciel/native rappellent
le besoin du pilote des deux apps et peuvent sortir avec le code 2 même si tous
les tests de support passent. Un binaire de sonde fourni n'est pas présumé compilé
depuis les sources courantes : depuis le lot du 20 octobre, le lanceur exige
le bundle QA réseau signé et son manifeste de provenance (Core reconstruit,
modules/archives, dépendances, sources et binaire inchangés). Une ancienne sonde
sans cette preuve retourne un prérequis manquant, sans lancement. Le script
`build-swift-probe.py --probe controller` réutilise les dépendances locales via
`--core-products`, construit un Core neuf et exige `--signing-identity` Apple
Development existante ; `--campaign-id` fixe l’identité QA au sein de la série.
Aucune installation ni nouvelle dépendance n’est nécessaire. Voir
[le rapport et les limites](QUALIFICATION_PREVERSION_MAC_2026-10-20_FR.md).

Chaque exécution crée un nouveau dossier privé `build/qa-runs/<run_id>`, jamais
écrasé : `report.json`, `report.md`, journaux expurgés et éventuels xcresult.
Le rapport relève HEAD **et l'empreinte des entrées locales non commitées**, les
binaires observés, la durée, le niveau de preuve et le résultat. Les mesures de
temps humain/interruption restent nulles tant qu'elles ne sont pas observées ;
utiliser `--human-minutes` et `--interruptions` pour les relever honnêtement.
Le temps entre reproduction et vérification exige un relevé de reproduction ;
la durée brute d'une exécution ne remplace pas cette mesure.

Codes de sortie : **0** résultats demandés vérifiés, **1** échec observé,
**2** préparation ou exécution manquante. Une prévisualisation, zéro test,
un appareil verrouillé ou une source modifiée pendant l'essai ne vaut pas réussite.
Le registre propriétaire n'est jamais modifié par le lanceur.

## Intégrations SourceKit et confinement hors XCTest

Depuis le lot approuvé du 19 octobre, la qualification Mac release construit `AIMProcessIntegrationQA` depuis les sources courantes. Les deux méthodes d’intégration SourceKit/confinement sont routées explicitement vers deux cas natifs obligatoires dans le même run ; les tests d’origine restent présents. Une sélection ciblée ne lance que les cas concernés ; quick Mac ordinaire n’exécute pas ces intégrations hors sélection. Le test de pipe fermé et les ProcessLifecycle restent sous XCTest protégé.

Le helper DEBUG exige un bundle QA privé, son namespace, home et run exacts. Il appelle les services AIM réels, sans initialisation AppModel/UI/permissions, avec un environnement minimal. La sandbox générale de XCTest reste active pour XCTest. Pour les hôtes natifs, l’exécution doit aussi sortir de la sandbox de l’outil (`require_escalated` dans Codex), conformément au périmètre autorisé : les sandboxes imbriquées empêchent les workers de démarrer. Il ne s’agit ni de sudo ni d’une désactivation du confinement des workers. Un home distinct n’est pas une isolation OS du compte ; aucun accès aux apps/données/paires n’est prévu.

SourceKit ne charge qu’un package synthétique. Le worker réellement confiné doit émettre un marqueur avant lecture : code témoin exact autorisé, faux secrets refusés. Une erreur sandbox_apply ne vaut pas protection validée. Les traces Objective-C doivent être actives, sans initialisation Contacts/XCTest observée. Des frameworks Contacts liés peuvent être chargés : leur présence seule n’établit pas une initialisation, et la trace ne constitue pas une garantie universelle sur les services OS.

Reçus nommés, source/binaire/run/fraîcheur et toutes les vérifications sont exigés. Crash, timeout, reçu absent/incohérent, trace manquante ou cas omis ne peuvent donner un succès. Le rapport sépare les comptes XCTest par bundle des deux cas natifs. Une release sortie 2 uniquement sur owner-release-gate reste une revue propriétaire à préparer, même lorsque ses étapes techniques passent. Voir [preuve complète](SOURCEKIT_CONFINEMENT_2026-10-19_FR.md).

## Ce que démontre le pilote

Le pilote construit une **nouvelle instance Mac DEBUG**, avec namespace aléatoire,
base en mémoire et secrets synthétiques stockés dans son dossier privé. Il ne
lit/exporte aucun trousseau et n'utilise ni helper installé, ni serveur cloud,
ni modèle payant. Le simulateur `AIM QA App Pilot` et le bundle iOS
`com.aimai.ios.qa.pilot` sont distincts des installations existantes.

Les panneaux QA appellent les coordinateurs, le store iPhone, les services RPC,
le chiffrement et les vérifications d'accès existants. Une confirmation sur le
Mac reste nécessaire ; l'agent utilise CUA pour observer la nouvelle fenêtre de **son seul PID**,
puis appuyer sur son bouton de confirmation. Le reçu hôte doit attester la paire
enregistrée ; une préparation ou un clic seul ne vaut pas confirmation. Ne jamais contourner l'accord Mac dans le
contrôleur pour faire réussir le test.

Le pilote vérifie lecture d'une conversation synthétique, empreinte du catalogue
(routes et bibliothèque comprises), conservation de la paire après relance,
reconnexion et respect de la déconnexion volontaire. Trois passages consécutifs
sont requis. Un quatrième test injecte un écart de catalogue et exige son
diagnostic à l'écran. Ce test négatif réussi ne transforme pas le catalogue
incorrect en réussite produit : l'incident détecté est conservé comme tel.

Les panneaux QA sont différents des écrans utilisateur ordinaires : ces derniers
ont leurs tests UI séparés. La conversation du pilote est préchargée ; le
fournisseur déterministe implémenté à la frontière NativeAgentTurnRunning est
réservé aux futurs essais de génération gratuits. Aucun vrai appel local/API
n'est inféré de la lecture de ce témoin. Les trois passages ne qualifient ni le
scanner physique, ni les réseaux mobiles, ni TURN Internet.

Les invitations sont détruites à la fin du pilote. Les journaux privés hôte,
les identités synthétiques et les xcresult peuvent contenir des détails de
qualification : ne pas publier leur dossier complet. Partager seulement les
reçus et extraits expurgés revus. Aucun QR actif ne figure dans les captures QA.

## Créneau physique, conservation et reprise

Un créneau est une autorisation réelle du propriétaire : apps exactes, appareil,
actions, début et expiration, au plus 45 minutes. Son enregistrement ne donne
aucune permission OS et n'étend pas sa portée. Exemple de saisie **après** cet accord :

```sh
python3 scripts/qa/session.py begin \
  --owner-authorization 'Message exact autorisant ce créneau' \
  --mac-bundle-id com.aimai.macos.qualification.ID_HEXA_32 \
  --ios-bundle-id com.aimai.ios.continuityqualification \
  --device-id IDENTIFIANT_APPAREIL \
  --allow observe --allow close --allow install --allow launch --allow control \
  --output .private/qa-session.json
python3 scripts/qa/session.py check .private/qa-session.json --action install
```

Remplacer les identifiants d'exemple ; ils échouent volontairement à la validation.
Relire le créneau avant chaque mutation. Tant que l'autre IA/personne utilise les
apps, aucune opération physique n'est autorisée par la simple approbation du plan.

Avant une mise à jour physique, utiliser la préparation et la distribution déjà
présentes dans `apps/macos/scripts` : vérification de signature/identité/droits,
fermeture autorisée, copie cohérente des données AIM et de l'ancienne app,
comparaison des fichiers, rollback conservé, installation puis comparaison avant
première ouverture. La lecture après lancement et l'utilisation des clés sont
des contrôles distincts. Ni export du trousseau, ni réassociation systématique.

L'agent doit préparer le binaire physique signé et son `.xctestrun`. Le lanceur
physique accepte uniquement une **nouvelle** app `com.aimai.ios.qa.*`, avec
signature vérifiée, identité correspondant au créneau et inventaire attestant
qu'elle n'est pas déjà installée. Une mise à jour d'app existante reste soumise
à la procédure de sauvegarde précédente, jamais automatisée implicitement.

```sh
python3 scripts/qa/run.py --suite remote --target device \
  --session .private/qa-session.json --device-test-run /chemin/AIM_iphoneos.xctestrun
```

Le scénario physique `AIMPhysicalScannerUITests` ouvre/ferme dix fois la vraie
caméra, alterne fermeture immédiate et attente, traverse accueil/retour et vérifie
réactivité et absence de nouvelle paire. Aucun faux appareil photo n'est injecté.
Ce scénario reste distinct de la preuve d'arrêt effectif de la caméra ; le rapport
conserve ce point à observer. Il n'est jamais sélectionné par la suite simulateur.
Sans créneau, candidat signé ou téléphone disponible, aucun essai n'est prétendu.
Les caméras simulées ne qualifient pas D04.
Déverrouillage, confiance, biométrie, vrais changements de réseau et observation
pendant la veille peuvent nécessiter une intervention : donner une action,
l'état attendu et la preuve à relever, puis reprendre au checkpoint.

## Boucle quotidienne et formation

Un brief utile précise résultat observable, périmètre, contraintes et fin :

> Corrige la reconnexion après relance. La paire existante doit être retrouvée
> sans QR et une déconnexion volontaire doit rester respectée. Utilise les
> identités QA sans appel payant. Reproduis, diagnostique, corrige et rejoue les
> vérifications pertinentes. Continue les opérations déjà autorisées, puis
> fournis les preuves et la prochaine action manquante.

L'agent conduit : reproduction → cause étayée → correction → vérifications
ciblées → diagnostic éventuel → rapport. Maximum trois tentatives correctives
sur le même défaut et 45 minutes par session. Il n'abaisse pas les assertions,
ne rejoue pas jusqu'à un succès chanceux et continue les travaux indépendants.
En DEBUG QA, `AIM_QA_FAULT=delay-request` ajoute un délai annulable avant RPC,
et `drop-reply-once` perd une réponse de commande **après** le retour du Mac.
Le wrapper ne rejoue rien et conserve les IDs ; le journal de commandes réel
décide des effets. Les traces `phone-rpc.jsonl` et `mac-rpc.jsonl` corrèlent ces
IDs, phases et opérations sans copier leurs payloads. Une réponse RPC n'est pas
un compteur d'effets ; les reçus des sondes natives attestent ce dernier séparément.
Le premier exercice de formation est l'écart de catalogue injecté : observer
`read-ok` mais `Catalog mismatch`, lire le reçu, différencier panne de lecture et
de publication, puis retirer l'injection et rejouer. Il ne prétend pas être un
nouveau défaut réel découvert chez le propriétaire.

Le développement du lanceur a aussi fourni un exemple de défaut réel : remplacer
globalement `PRODUCT_BUNDLE_IDENTIFIER` affectait les frameworks SwiftPM et
empêchait l'installation iPhone. Le xcresult a identifié les identifiants
dupliqués ; la correction utilise une variable limitée à la cible app,
`AIM_APP_BUNDLE_IDENTIFIER`. Les deux tests UI ont ensuite passé. Ce diagnostic
illustre le cycle complet sans demander au propriétaire de reproduire le défaut.

Mesurer avant/après sur le même scénario : minutes humaines, interruptions,
temps reproduction→vérification et scénarios reproductibles avec preuves.
Un gain non mesuré ne doit pas être annoncé.

## CI et outils optionnels

Le workflow conserve ses déclencheurs habituels et vérifie le registre/lanceur.
L'exécution UI iPhone est disponible par `workflow_dispatch`, entrée
`run_ios_ui=true`, sur le job Mac existant. Vérifier d'abord le quota de minutes.
Aucun nouveau run distant n'est déclenché par cette implémentation.

MobileBuildMCP est installé sans scripts npm ni modification globale :

```sh
npm ci --prefix tools/apple-qa --ignore-scripts --no-audit --no-fund
MOBILEBUILDMCP_SENTRY_DISABLED=true tools/apple-qa/node_modules/.bin/mobilebuildmcp --help
MOBILEBUILDMCP_SENTRY_DISABLED=true tools/apple-qa/node_modules/.bin/mobilebuildmcp simulator list --output json
```

Son aide et la lecture de l'inventaire simulateur ont été contrôlées localement.
Cela ne certifie pas son contrôle UI d'un iPhone physique. Le lanceur fonctionne
avec les outils Apple standards même sans cet outil optionnel. Les exemples
d'installation globale/latest du skill tiers ne s'appliquent pas à ce projet.

## Registre et limites d'acceptation

`controls.json` reprend les 71 résultats attendus du registre propriétaire,
scénarios T01–T27, préparations complémentaires, suites de support existantes et
preuves manquantes. Après évolution des guides ou tests : revoir les associations,
puis `python3 scripts/qa/catalog.py` et `--check`. Le contrôle de dérive est volontaire.

Le fichier `VALIDATION_AVANT_PUBLICATION_FR.md` reste la décision d'acceptation.
Tests logiciels, intégration native, panneaux QA, UI ordinaire, appareils réels,
inférence réelle et publication sont des preuves distinctes. La revue finale et
l'accord propriétaire restent requis.

## Contrats LAN et annulation — 20 octobre 2026

`python3 scripts/direct/test-lan-contracts.py --probe <HELPER_COURANT> --output <DOSSIER_NEUF>` exécute normal,absent,late,cancel,cancel-before. Les observations de lien de contrôle restent distinctes des scénarios complets, apps et appareils. Late(1,5s) est attendu connecté dans le budget ; absent/cancel restent des incidents sans observation connectée. La série diagnostique initiale ne se rejoue pas pour chercher un résultat. QA08 demeure ouvert ; QA14 annulation est corrigé. Voir [rapport et limites](QA08_DIAGNOSTIC_2026-10-20_FR.md).

Si le contrôle CUA est indisponible, ne pas contourner la confirmation : demander le clic réel sur le seul hôte QA. Le libellé driver statique du pilote ne prouve pas une action CUA ; consigner le driver réellement utilisé et conserver l’échec initial. Aucune modification de réglage système implicite.
