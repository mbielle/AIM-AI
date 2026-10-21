# Procédures publiques T01–T27

> **Adaptation publique de l’export alpha, 21 octobre 2026.** Ce texte est dérivé du dossier de travail ; il ne reproduit pas les preuves opérationnelles privées. Les résultats historiques gardent leur portée et ne valent pas validation du candidat ou autorisation de publication.

Guide de manipulation, pas reçu de validation. Choisir les candidats et l’environnement de qualification, préserver la paire et les données existantes, préparer les copies ciblées et un repli avant toute mise à jour autorisée. Aucun effacement ou réappairage n’est demandé. Les tests d’erreurs utilisent un profil distinct et des fichiers inoffensifs.

Pour chaque résultat : scénario, versions réellement utilisées, cible, modèle/fournisseur, réseau, résultat attendu puis observé. Ne jamais partager clé, QR actif ou donnée personnelle. Un prérequis absent se note À PRÉPARER. Aucun appel payant, téléchargement lourd ou changement d’infrastructure sans autorisation propre au nouvel essai ; les montants donnés dans les scénarios sont des paramètres de test, pas des crédits accordés. N01 doit être prêt avant T25–T27.

Ces procédures ne lancent pas la campagne QA isolée abandonnée. Le [registre](VALIDATION_AVANT_PUBLICATION_FR.md) et le [suivi des 71 contrôles](qa/SUIVI_71_CONTROLES_2026-10-19_FR.md) restent distincts.

### T01 — conservation après ouverture (D03)

1. Ouvrir les deux apps de test.
2. Sur iPhone, ouvrir le projet de qualification : retrouver conversation, document,
   instructions et brouillon éventuel. Sur Mac, retrouver ses propres données et
   réglages — ils ne sont pas censés devenir une copie du profil local iPhone.
3. Dans les réglages Remote Mac, vérifier que l'iPhone est toujours associé.

Attendu : pas d'erreur au démarrage, pas de disparition de données ni nouveau QR.
Les copies avant lancement et la lecture après réouverture restent des contrôles distincts.

### T02 — connexion et cible d'exécution (L01, première partie L02, D05)

1. Laisser les deux appareils sur le même Wi-Fi, Mac éveillé et AIM ouvert.
2. Sur iPhone, ouvrir le point vert et toucher **le nom du Mac**.
3. Toucher la barre de saisie puis le modèle. Vérifier **Sur [nom du Mac]**.
4. Revenir au point vert, choisir **Cet iPhone**, puis revenir au Mac.

Attendu : la coche et le catalogue suivent le choix. Cet iPhone affiche ses
fournisseurs ; le Mac affiche les siens. **Online** inclut les API exécutées par
le Mac. **Local · Mac** désigne les moteurs qui tournent réellement localement.
« Gérer les Mac » ouvre la gestion des connexions, pas le choix de la cible.

### T03 — reconnexion automatique et déconnexion volontaire (D05, R03)

1. Avec une paire connectée, fermer normalement l'app iPhone puis la rouvrir.
2. Vérifier que le Mac associé est retrouvé sans nouveau QR.
3. Ouvrir Gérer les Mac, choisir Déconnecter ; fermer puis rouvrir l'app.
4. Vérifier qu'elle respecte cette déconnexion. Toucher ensuite le nom du Mac pour
   reconnecter, puis sélectionner le Mac comme cible si nécessaire.

Attendu : reconnexion possible sans nouvelle association ; aucune substitution
silencieuse d'un autre Mac ou de l'appareil exécutant. La connexion automatique
ne doit pas forcer l'exécution sur Mac lorsque Cet iPhone est choisi.

### T04 — scanner et annulation (D04, partie L07)

1. Gérer les Mac → Ajouter un Mac ; ouvrir puis fermer le scanner **dix fois**.
2. Alterner fermeture immédiate et fermeture après quelques secondes.
3. Une fois, passer à l'accueil iPhone puis revenir et fermer le scanner.
4. Ne scanner aucun nouveau QR pour ce test ; vérifier la paire existante.

Attendu : aucune pause prolongée, relance, caméra restant active après fermeture,
ni association créée par l'annulation. Noter la durée d'une pause et filmer si elle
se reproduit. Le simulateur sans caméra ne valide pas ce test physique.

### T05 — droits modifiables sans nouvelle association (L03, L04, L05)

1. Sur Mac : Settings → Remote → iPhone → Permissions ; noter les droits actuels.
2. Retirer uniquement **Use terminal**, enregistrer. Sur iPhone, laisser la
   reconnexion finir puis ouvrir Security details : Terminal doit être absent.
3. Restaurer explicitement ce droit sur Mac, vérifier son retour sans QR.
4. Couper l'autorisation globale de connexion iPhone sur Mac : la connexion doit
   être refusée. La réactiver et reconnecter la paire existante.

Attendu : nouveaux droits effectifs côté Mac, état iPhone cohérent, données
conservées. Le refus réel d'une commande retirée est testé en T18, dans le dossier
inoffensif préparé pour cela ; ne pas utiliser un dossier personnel.

### T06 — navigation et présentation (D06, D07, D08)

1. Sur chaque app, ouvrir un projet, une conversation, revenir au projet puis à la
   liste des projets. Sur iPhone, vérifier aussi les retours par glissement.
2. Ouvrir le clavier, saisir un brouillon long, fermer le clavier, rouvrir la
   conversation. Aucun texte ni bouton ne doit passer sous le clavier.
3. Tester clair/sombre, petite/grande fenêtre Mac et grands caractères iPhone.
4. Dans le sélecteur, passer plusieurs fois entre bibliothèque/catalogue et
   Online/Local avec **un seul appui normal** par changement.

Attendu : pas de saut de navigation, bouton inaccessible, chevauchement, date ou
séparateur inutile dans la liste de conversations. Les aperçus ne montrent pas
les étoiles du Markdown. La barre du haut Mac est recontrôlée en T07 sur le candidat choisi.

### T07 — barre du haut pendant le sélecteur (D07)

1. Ouvrir le sélecteur Mac ; comparer la barre des feux rouge/jaune/vert au reste du
   fond grisé. Fermer et rouvrir le panneau.
2. Refaire en clair/sombre, fenêtre redimensionnée puis plein écran.

Attendu : le voile couvre aussi le haut, aucune bande blanche distincte, contenu
et boutons du panneau lisibles. Ce point demande une vraie observation Mac.

### T08 — premier usage sans fournisseur (D08, D09)

Ce test demande un **profil/app de qualification vierge préparé par l'agent**.
Ne pas supprimer les clés ni réinitialiser le profil actuel pour le simuler.

1. Ouvrir le sélecteur : aucun modèle prédéfini dans la bibliothèque.
2. Toucher **Connect a provider** : les réglages Providers doivent s'ouvrir.
3. Revenir sans rien enregistrer : la bibliothèque reste vide et utilisable.

Attendu : aucun catalogue public de référence présenté comme une connexion ou
une bibliothèque personnelle ; aucune clé ajoutée par la navigation.

### T09 — constituer, modifier et conserver la bibliothèque (D08, partie L02)

1. Avec le fournisseur Mac déjà connecté, ouvrir le sélecteur. Sans choix antérieur,
   l'accueil propose de construire la bibliothèque.
2. Choisir **Choose models/Add models**, chercher un modèle et l'ajouter avec +.
3. Revenir à **My models** : seul ce choix et les anciens ajouts/épingles explicites
   doivent apparaître. Ajouter un deuxième modèle, retirer l'un des ajouts.
4. Pour un modèle non ajouté, ouvrir sa fiche et choisir **Use model** : ce choix
   explicite doit aussi l'ajouter à la bibliothèque.
5. Fermer/rouvrir le panneau puis l'app Mac : choix conservés.
6. Sur iPhone en ciblant Mac, comparer la liste ; utiliser **Actualiser le catalogue**
   si la publication est encore en cours. Vérifier aussi le catalogue complet.

Attendu : aucun retour des modèles prédéfinis, choix visibles sur iPhone, pas de
transfert de clé. Une épingle est également un choix de bibliothèque ; pour enlever
le dernier modèle, retirer à la fois son ajout et son épingle éventuelle.

### T10 — dernier modèle et fournisseur mémorisés (D08)

1. Choisir un modèle de la bibliothèque Mac : son nom remplace Add models dans le
   compositeur, sans envoyer de message.
2. Ouvrir New chat, fermer puis rouvrir AIM : retrouver le même modèle **et la même
   route fournisseur**. Si deux clés donnent accès au même modèle, vérifier la route.
3. Après un essai IA autorisé en C, refaire cette vérification avec le modèle utilisé.

Attendu : aucun retour à Choose model lorsqu'un choix existe. Avant toute première
sélection, Add models est normal : l'app ne doit pas inventer un dernier modèle.
Un modèle propre à une ancienne conversation reste affiché pour cette conversation.
Les défauts Code/Agent explicitement configurés se vérifient séparément en T18.

### T11 — référence locale puis même requête via iPhone (I01, I02, L02)

1. Avec l'agent, identifier un modèle local déjà prêt et son moteur. Les catalogues
   et vérifier sa disponibilité sans inférer une route locale du seul transport LAN.
2. Depuis AIM Mac, lui envoyer : **Réponds exactement : AIM-LOCAL-OK-731.**
3. Depuis iPhone, choisir le Mac et le même modèle local ; envoyer la même demande.
4. Ouvrir la conversation/activité correspondante sur Mac et comparer la réponse.

Attendu : demande exécutée sur Mac, réponse/streaming sur iPhone, pas de route cloud.
Le transport local seul ne prouve pas que le modèle est local. Si aucun modèle
compatible n'est prêt, noter À PRÉPARER et faire décider la préparation par l'agent.

### T12 — référence API puis même requête via iPhone (I03, I04)

Choisir une route fournisseur et un plafond explicitement autorisés pour ce nouvel essai ; rapprocher la consommation réelle déjà engagée. Ce guide ne renouvelle aucune autorisation historique. Garder le budget actif et la recherche désactivée.

1. Budget AIM estimatif au plafond autorisé activé sur le dispositif exécutant, envoyer depuis AIM Mac :
   **Réponds exactement : AIM-MAC-OK-842.**
2. Vérifier réponse, usage/coût et activité chez le fournisseur.
3. Depuis iPhone, cibler le Mac et la même route ; envoyer :
   **Réponds exactement : AIM-REMOTE-OK-953.**
4. Comparer conversation/activité Mac et résultat iPhone. Relever les deux coûts.

Attendu : un appel logique par envoi ; aucune deuxième génération iPhone, aucune
facturation déclarée gratuite lorsqu'un coût est inconnu. Deux demandes différentes
correspondent bien à deux appels, pas à un doublon.

### T13 — exécution iPhone explicite et retour vers Mac (I05)

Choisir Cet iPhone puis un modèle de son fournisseur déjà autorisé. Envoyer une
courte demande témoin différente, puis revenir au Mac. Attendu : route iPhone
identifiée, paire Mac toujours conservée. Ne pas tester Anthropic sur iPhone en
supposant que la clé Mac y a été synchronisée.

### T14 — arrêt, double appui, erreurs et budget (I06, I07, I08)

1. Avec un modèle local, demander un texte long puis Arrêter depuis iPhone. La
   production Mac doit s'arrêter et le texte partiel rester consultable.
2. Avec ce modèle local, faire un double appui rapide sur Envoyer pour une petite
   demande : une seule tâche/réponse logique doit être créée.
3. Sur le profil vierge préparé pour les erreurs, essayer une route sans clé ou un
   modèle devenu indisponible : erreur utile, brouillon intact, aucun autre modèle
   payant choisi automatiquement.
4. Pour l'API autorisée, vérifier un petit appel avec budget 5 $ actif ; vérifier
   les refus de budget insuffisant/protection stricte dans la configuration de
   qualification préparée par l'agent, puis remettre les réglages initiaux.

Attendu : coût partiel connu conservé, frais inconnus indiqués dans les informations,
pas de blocage global causé par une ancienne charge non quantifiable en mode
estimatif. Ne pas épuiser volontairement les 5 $ ni fabriquer une charge réelle
pour tester le dépassement. L'agent teste les calculs/limites avec des fixtures.

### T15 — projet, instructions, source et exclusion (I09)

Sur un projet de qualification de chaque app, ajouter une note portant un code
unique inédit ; instruction : **Commence les réponses par « TEST-PROJET ».**
Demander le code en citant la source. Attendu : bon code, préfixe et nom du fichier,
sans UUID ni chunk affichés. Exclure la note et démarrer une **nouvelle conversation**
avant de redemander : le modèle ne doit pas retrouver le code dans un ancien échange.
Réactiver puis retester. Renommer la note, vérifier aperçu, brouillons distincts et
conservation après réouverture. Utiliser le modèle local si ses outils sont compatibles,
sinon ne poursuivre qu'avec le fournisseur et budget autorisés.

### T16 — recherche, activité, liens et logos (I10, I12)

Avec une route de recherche expressément autorisée et son budget disponible, demander :
**Cherche la documentation officielle Swift, donne son lien et résume-la en deux
phrases. Cite les sources.** Refaire directement sur Mac puis via iPhone ciblant Mac,
uniquement si le budget restant l'autorise.

Attendu : liens ouvrables et pertinents ; une seule durée globale ; réflexion
fournisseur repliée ; événements réels de recherche/résultats/lecture distingués.
Une simple citation n'est pas une preuve de visite. Si OpenRouter ne fournit pas
le domaine en direct, son absence ne doit pas être remplacée par une fausse animation.
Ouvrir Sources : icône si disponible, sinon globe, aucune lettre de remplacement.
Les frais connus ne sont comptés qu'une fois ; l'absence de coût n'est pas 0 $ garanti.
Les moteurs AIM Exa/Brave (I11) attendent clés/budgets et comparaison préparés par l'agent.

### T17 — clavier, streaming, copie et lecture (D06, F05 partiel)

Pendant une réponse locale longue : ouvrir/fermer le clavier iPhone, remonter
manuellement lire un passage, revenir en bas. Attendu : suivi progressif sans grands
sauts, lecture manuelle respectée, pas de trou blanc durable après fermeture du
clavier. Tester Copier, les informations de réponse et la lecture à voix haute si
configurée. Aucun enregistrement ni fournisseur vocal payant nouveau sans accord.

### T18 — Code/Agent et approbations sur dossier inoffensif (F01, F02, L04)

L'agent prépare un dossier temporaire dédié. Utiliser un modèle local outillé ou le
fournisseur expressément autorisé. Dans Code/Agent, demander de créer uniquement
`aim-test.txt` avec le texte `AIM-TOOL-OK`, dans ce dossier. Refuser d'abord
l'approbation : aucun fichier ne doit être créé. Relancer, approuver cette seule
action, comparer sur Mac. Retirer le droit terminal comme en T05 puis demander une
commande de qualification : refus côté Mac. Restaurer explicitement le droit.
Vérifier également les défauts de modèle Code/Agent configurés. Ne pas utiliser
un dépôt réel, ni une commande destructive pour ce test.

### T19 — iPhone fermé/verrouillé, tâche Mac conservée (R01, R03)

Avec une tâche locale suffisamment longue, relever son identifiant, fermer l'app
iPhone puis la rouvrir. Refaire en verrouillant seulement l'écran. Attendu : tâche
continuée sur Mac quand ses permissions le permettent, même identifiant, résultat
retrouvé et aucune réexécution. La durée de test est préparée avec l'agent ; ne pas
multiplier des générations API pour rendre une tâche artificiellement longue.

### T20 — coupure Wi-Fi iPhone et retour (R02)

Pendant une tâche locale connue, couper brièvement le Wi-Fi iPhone puis le remettre.
Sans service Internet préparé, ne pas attendre une connexion 4G réussie pendant la
coupure. Attendu au retour LAN : reconnexion, même tâche et un seul résultat/effet.

### T21 — disponibilité du Mac et redémarrage (R04, R05)

Sans travail personnel en cours dans AIM, quitter normalement AIM Mac puis le
rouvrir. Tester ensuite verrouillage/déverrouillage, veille/réveil, et enfin
redémarrage des appareils à un moment convenu. Attendu : disponibilité honnête,
reprise depuis le journal, aucune action d'interface pendant un verrouillage qui
l'interdit, aucune commande incertaine exécutée deux fois. Le Mac doit être disponible
pour travailler ; l'absence de réponse pendant sa veille n'est pas un succès Remote.

### T22 — pièce jointe et interruptions (R07)

Envoyer un petit fichier de qualification autorisé depuis iPhone vers la tâche Mac,
comparer son contenu ; interrompre puis reprendre un transfert. L'agent fournit un
fichier dépassant la limite annoncée pour le refus de taille. Attendu : intégrité,
erreur claire, pas de pièce provenant d'une autre paire/profil, pas de transfert doublé.

### T23 — QR invalides et révocation (L06, L07, L08, R06)

À faire **en dernier avec une paire de qualification distincte préparée par l'agent**.
Essayer QR expiré, déjà utilisé, invalide et un appareil non appairé ; puis révoquer
cette paire sur Mac pendant une coupure et tenter de revenir. Attendu : refus côté
Mac, anciens droits/messages inutilisables ; nouvelle association seulement après
nouveau QR et accord Mac. La paire actuelle est conservée pour les autres essais.

### T24 — réseau local réellement isolé et permissions réseau (L09, L10)

L'agent prépare un réseau de test sans Internet, sans couper le réseau de travail.
Tester lecture et modèle local via iPhone/Mac : aucun service AIM public requis.
Tester ensuite refus puis restauration de l'autorisation Réseau local sur un profil
ou appareil de qualification. Attendu : message utile et récupération, aucune boucle
ni réinitialisation forcée. Un appel cloud ne peut pas valider ce test hors Internet.

### T25 — véritable réseau mobile (N02, N03)

Après N01 et les vrais appels LAN : Mac sur son Wi-Fi habituel, iPhone Wi-Fi coupé,
4G/5G constatée ; pas de partage de connexion Mac via l'iPhone. Reprendre la paire,
lire une conversation puis envoyer un court message au modèle local Mac.
Attendu : état Internet direct ou relayé correspondant au diagnostic réel. Une
simple étiquette ne suffit pas à qualifier la paire ICE choisie.

### T26 — relais forcé et changement de réseau (N04, N05)

L'agent force TURN dans la configuration de qualification, sans changer les droits.
Exécuter la demande locale puis passer Wi-Fi → mobile → Wi-Fi pendant une tâche.
Attendu : allocation réelle relayée, contenu chiffré, même tâche et un seul effet.
La contrainte TURN est ensuite retirée explicitement.

### T27 — panne, quotas et installation personnelle (N06, N07, N08, N09)

Avec l'agent sur infrastructure de qualification : réseau UDP bloqué, serveur
indisponible, certificat invalide, allocation expirée/quota atteint. Attendu : relais
si disponible, sinon refus utile sans boucle ni dépassement facturé ; LAN direct
préservé. Installer le service personnel depuis le guide et refaire lecture/IA/reprise.
L'agent joint les mesures, preuves TLS/chiffrement et coûts ; le propriétaire valide
le devis, les alertes et l'absence de dépassement automatique.
