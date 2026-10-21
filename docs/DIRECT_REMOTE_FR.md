# Connecter AIM sur iPhone directement au Mac

Ce guide concerne le nouveau parcours **Direct connection** des applications natives. Le parcours Remote avec compte et Supabase reste distinct. La connexion directe contrôle le **profil local du Mac** ; elle ne transforme pas le profil local en compte et ne fusionne pas les conversations des deux appareils.

## Avant de commencer

- Utiliser les versions Mac et iPhone qui contiennent ce parcours. Sa compilation et les tests automatisés ne remplacent pas la qualification sur les deux appareils.
- Conserver les applications officielles et leurs données. Pour une qualification, préférer les applications de test isolées déjà préparées. Copier seulement les données AIM avant de remplacer leur build ; aucune sauvegarde complète du Mac ou de l’iPhone n’est nécessaire pour ce parcours de test.
- Pour le premier essai, placer les appareils sur le même réseau local, laisser le Mac éveillé et AIM ouvert. Ne pas activer le mode privé global pendant cet essai.
- Aucun fournisseur ni envoi à un modèle n’est nécessaire pour appairer les appareils, lire la liste des conversations ou vérifier la liaison.

## Appairer les appareils sur le réseau local

Le parcours ci-dessous correspond au candidat 52. Le propriétaire a confirmé le
premier appairage physique du build 51 avec le statut « Direct · local network »
et la conservation des données après réouverture des deux apps. Cela ne qualifie
pas encore la lecture d'une conversation, les modifications de droits ou Internet.
Les deux apps doivent recevoir le nouveau candidat avant de tester les droits.

1. Vérifier le profil **Local** sur les deux appareils. Sur le Mac, ouvrir
   **Settings → Remote → iPhone connection** et activer **Allow iPhone connections**.
2. Ouvrir **Computer connection** sur l'iPhone avant de générer le code. Sur le Mac,
   cliquer **Add iPhone…**. Le code valable deux minutes apparaît dans un panneau.
   **Connection options** reste fermé pour le réseau local ; aucune URL n'est requise.
3. Sur l'iPhone, toucher **Scan a Mac QR code** (ou **Add a Mac**), autoriser la
   caméra et le réseau local si demandé, puis scanner. La caméra disparaît dès la
   reconnaissance. Vérifier le nom du Mac puis toucher **Connect to this Mac**.
4. Sur le Mac, vérifier l'iPhone en attente dans le même panneau puis cliquer
   **Confirm iPhone**. **Choose permissions** permet de limiter l'accès ; la lecture
   est obligatoire. Le QR seul n'accorde aucun accès. Les empreintes complètes
   restent consultables dans les détails de sécurité des deux appareils.
5. L'iPhone doit afficher **Connected · local network** pour le Mac sélectionné et
   une action **Disconnect**, sans ancien message de connexion encore en attente.
   Les autres Macs enregistrés gardent leur action **Connect**.

Le lien manuel est accessible depuis **Paste a pairing link instead** dans le
panneau de scan. Le champ de serveur Internet reste sous **Connection options**
sur le Mac et s'applique à la prochaine invitation, pas aux appairages existants.

### Modifier les droits d'un iPhone

Sur le Mac, dans **Paired iPhones**, cliquer **Permissions…** sur l'appareil voulu.
Les réglages affichés sont exactement ceux de cet appairage. Garder **View activity**
et choisir les autres droits, puis **Save permissions**. Le même appairage reprend
avec une nouvelle révision signée ; aucun nouveau QR ni transfert de clé n'est
nécessaire. L'accès précédent et les commandes en attente sont invalidés ; les contrôles et
tâches actifs pilotés par cet iPhone peuvent être interrompus. Une
ancienne réponse privilégiée mémorisée n'est pas révélée sous des droits réduits
et son effet n'est jamais rejoué ; les instantanés de tâches restent distincts.
Les budgets fournisseurs et les approbations Mac continuent de s'appliquer.

Pour retirer complètement l'accès, ouvrir le menu **… → Remove access…** puis
confirmer. Cette révocation exige un nouvel appairage pour autoriser de nouveau
l'iPhone. Une déconnexion volontaire conserve l'appairage sans se reconnecter seule.

## Vérifications sans appel modèle

Effectuer un contrôle à la fois et conserver le résultat observé.

1. **Lecture** : créer sur le Mac une conversation de qualification contenant uniquement du texte synthétique, ou utiliser une conversation de test déjà existante. Vérifier son titre et son contenu sur l’iPhone. Ne pas envoyer de question à un modèle pour ce contrôle.
2. **Séparation des profils** : vérifier que des conversations du compte connecté ne deviennent pas visibles dans la connexion directe au profil local. Une connexion à un compte sur le Mac doit interrompre l’accès direct au profil local précédent.
3. **Reconnexion** : quitter seulement l’écran de connexion sur l’iPhone, puis y revenir. Une liaison souhaitée reprend au retour au premier plan ; **Connect** permet une reprise explicite si nécessaire. Une déconnexion volontaire ne doit jamais se reconnecter seule. Ne pas créer un nouvel appairage à chaque ouverture.
4. **Mac indisponible** : couper temporairement la liaison réseau de l’iPhone ou fermer l’application de test Mac après avoir enregistré son travail. L’iPhone doit afficher une indisponibilité ou une reconnexion, sans prétendre qu’une commande est terminée. Les tâches admises sur un Mac encore actif ne sont pas annulées par une simple perte de transport.
5. **Arrêt puis réactivation** : désactiver **Allow iPhone connections** sur le Mac. L’accès doit s’interrompre. Le réactiver puis reconnecter l’iPhone ; un appairage enregistré et non révoqué doit pouvoir être réutilisé.
6. **Révocation** : ouvrir **… → Remove access…** pour l’iPhone dans la liste du Mac et confirmer. L’ancien appairage doit être refusé, y compris après reconnexion. Un nouvel appairage exige une nouvelle invitation et une confirmation sur le Mac.
7. **Refus des permissions** : avec un appareil limité à la lecture et Chat, vérifier que les opérations Code, Agent, terminal, réglages et approbations non accordées sont refusées ou absentes. La gratuité n’accorde aucune de ces permissions implicitement.

### Fichiers, terminal et navigateur

Ces parcours réutilisent les interfaces natives existantes. Ne pas lancer un appel modèle pour les qualifier tant que le fournisseur et le budget n’ont pas été explicitement choisis.

- **Fichier** : dans une conversation de qualification distante, ajouter un petit fichier texte synthétique. Vérifier la fin de l’import. L’envoi au modèle reste une étape séparée. Les fichiers transitent par le canal chiffré, par blocs bornés ; le Mac vérifie la taille, le condensat, l’appairage et la conversation avant de les utiliser. Le plafond technique est de 20 Mio par fichier, quatre références par message ; les imports temporaires non utilisés expirent.
- **Terminal** : dans une conversation Code ou Agent de qualification associée à un dossier synthétique, autoriser explicitement la permission **Terminal** sur le Mac puis utiliser l’action terminal avec `pwd`. Vérifier le chemin attendu et le code de sortie. Ne pas exécuter de commande destructive, de gestionnaire de paquets ou d’appel réseau pour ce premier essai.
- **Diff** : utiliser un petit dépôt de test avec une modification connue. Vérifier que le diff et les fichiers affichés correspondent à ce dépôt. Aucun accès hors du dossier autorisé ne doit être obtenu.
- **Navigateur** : utiliser l’action navigateur native et une page locale de qualification. Le navigateur doit être disponible dans l’installation Mac. Une fonction absente doit être présentée comme indisponible ; une simulation de page ou d’action ne constitue pas une réussite.
- **Révocation pendant une action** : vérifier qu’une commande terminal ou une session navigateur contrôlée par cet appareil cesse lors de sa révocation. Ne pas employer une tâche utile pour cet essai.

Une réponse perdue peut signifier que le Mac a déjà admis l’action. Le client conserve l’identifiant d’une commande incertaine dans le profil local ; la rejouer après reconnexion ne doit pas exécuter une seconde fois son effet. Un état **outcome unknown** impose de vérifier la conversation ou le dossier du Mac avant de tenter une autre action.

## Se connecter par Internet

Le parcours Internet nécessite une installation de signalisation et, selon les réseaux, un relais TURN. Il n’est pas équivalent au parcours local sans serveur.

1. Préparer sa propre installation avec [le guide du coordinateur](../server/direct/README.md). Utiliser HTTPS/WSS et la configuration TURN propre à cette installation.
2. Sur le Mac, saisir son URL WSS dans **Connection options → Custom connection server**, puis générer une nouvelle invitation. L’invitation indique cette installation ; ne pas réutiliser un QR expiré ou provenant d’une autre machine.
3. Reprendre la comparaison d’empreintes et la confirmation explicite sur le Mac.
4. Tester les appareils sur deux réseaux distincts. Contrôler le libellé effectif **Direct · peer to peer** ou **Relayed · encrypted TURN transport**. Un label seul ne prouve pas que le trafic a emprunté le chemin attendu : conserver aussi les résultats de la qualification native du transport.
5. Tester séparément la veille, le retour réseau, la reconnexion et la révocation.

Ne pas publier l’accès Internet avant d’avoir qualifié l’installation, ses limites et les coûts de relais. Le coordinateur ne remplace pas les clés privées des appareils ni les permissions accordées sur le Mac.

## Mode privé et limites de validation

Le mode privé global bloque les transports AIM gérés, y compris la découverte réseau local, la signalisation et WebRTC. Sa préparation attend la fermeture attestée des transports opaques ; une demande d’arrêt seule ne prouve pas leur fermeture. Les conversations, clés et appairages enregistrés restent conservés.

La liaison directe n’est pas une synchronisation générale des projets ou de tous les historiques entre profils. Les objectifs continus, l’assignation d’un projet et l’épinglage distant ne sont pas annoncés par cet adaptateur tant que leurs contrats ne sont pas fournis. Les capacités du navigateur et des opérations de session dépendent également du runtime Mac réellement disponible.

Les tests automatisés couvrent les instantanés et longues réponses, les permissions et profils, les commandes incertaines après redémarrage du client, les transferts bornés et leurs condensats. Les essais natifs de transport sont documentés séparément. Les parcours caméra, autorisations réseau iOS, veille réelle, mise à jour et contrôle bout en bout sur l’iPhone et le Mac restent des validations physiques à réaliser ; ce document ne les déclare pas réussis.
