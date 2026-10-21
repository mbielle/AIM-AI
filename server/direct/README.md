# Coordination et relais AIM Direct

Ce composant ne nécessite pas de compte Supabase. Les applications gardent leurs
clés et permissions ; le serveur vérifie les signatures des appareils et transmet
la signalisation chiffrée. Il ne reçoit pas les clés de déchiffrement des commandes.
Le transport Supabase existant reste disponible séparément.

## Vérification locale

Node 22 ou supérieur :

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm test
AIM_DIRECT_STATE=/tmp/aim-direct-synthetic-state.json npm start
```

Le serveur écoute `127.0.0.1:8789`. Les tests créent uniquement des identités
synthétiques. Pour tester les clients natifs, construire la dépendance avec
`python3 scripts/direct/build-native.py --cache /tmp/aim-direct --fetch --assemble`
depuis la racine (Xcode et CMake requis), puis suivre les scripts de qualification
dans `scripts/direct`. Le mode `ws://` est réservé au loopback des harnesses ;
une installation accessible par les applications exige `wss://` et un certificat valide.

## Installation personnelle sur Linux

Le déploiement fourni est à **qualifier sur un VPS vide** avant activation publique.
Il n'a pas été exécuté dans Docker sur la machine de développement. Ne pas pointer
ces commandes vers les données d'une installation existante.

1. Choisir un hébergement à forfait ; compléter une copie privée de
   `deploy/hosting-quote.example.json`. Le coût mensuel total doit être au plus
   **20 EUR**, taxes et ressources incluses, sans dépassement facturable ni recharge
   automatique. Fixer `includedTrafficBytes` au trafic réellement compris. Le
   générateur refuse les devis absents, périmés ou incompatibles. Cette vérification
   de configuration ne vérifie pas le contrat du fournisseur à la place de l'opérateur.
2. Préparer deux domaines, `connect` et `relay`, pointant vers l'IPv4 publique du
   serveur. Obtenir un certificat couvrant les deux noms, puis assembler chaîne et
   clé privée dans `.private/tls.pem` (droits 600). Prévoir son renouvellement et le
   redémarrage du proxy après remplacement. Aucun certificat privé dans Git.
3. Copier `.env.example` vers `.env`, générer deux secrets indépendants avec
   `openssl rand -hex 32`, renseigner domaines, IP, chemins et quota. Exécuter avec
   un utilisateur de service dédié, pas un compte contenant d'autres applications :

   ```sh
   node --env-file=.env render-deployment.mjs
   docker compose --env-file .private/deploy/compose.env -f deploy/compose.yaml config --quiet
   docker compose --env-file .private/deploy/compose.env -f deploy/compose.yaml build
   ```

   Les fichiers restent 600, le répertoire d'état 700. Compose utilise le même
   UID/GID que le générateur pour le coordinateur. Vérifier l'accès avec l'UID
   effectif du conteneur ; ne pas résoudre un problème d'accès avec `chmod 777`.
4. Ouvrir uniquement TCP 443, UDP 3478 et UDP 49160–49223. Ne pas publier 8789,
   le port d'administration ni le TCP interne TURN. HAProxy termine TLS sur 443
   et sélectionne le backend par SNI : WebSocket pour `connect`, TURN pour `relay`.
   Le certificat et le DNS doivent être valides depuis les deux appareils.
5. Valider la configuration HAProxy et coturn dans leurs images épinglées, puis
   démarrer avec `docker compose ... up -d` (mêmes arguments que ci-dessus).
   Vérifier santé, refus sans signature, appairage, direct Internet et relais forcé
   avec des profils synthétiques. Le relais ne peut être annoncé opérationnel avant
   ces contrôles. Les images sont épinglées par digest dans Compose.

## Limites, métriques et exploitation

`/health` ne publie aucune identité ; `/metrics` exige le jeton administratif.
Il expose connexions, rejets, octets WebSocket et **réservations** de trafic TURN.
Ce dernier compteur n'est pas une mesure des octets réellement facturés. Configurer
le moniteur `monitor.mjs` sous supervision : il relève toutes les trente secondes
les seuils 75 %, 90 %, épuisement et indisponibilité, puis écrit des alertes JSON
et leurs résolutions sans jeton ni identité. Dans le conteneur coordinateur,
`node monitor.mjs` réutilise son environnement et l'adresse loopback. Hors conteneur,
configurer `AIM_DIRECT_METRICS_URL` HTTPS et le jeton administratif privé. Raccorder
ces événements au service d'alertes choisi par l'opérateur ; aucune notification
externe n'est envoyée automatiquement par ce dépôt. Surveiller aussi les octets
réseau réels du VPS, distincts des réservations.

Le TTL REST TURN ne suffit pas à arrêter une allocation déjà authentifiée : coturn
peut la prolonger par Refresh. Le déploiement inclut donc un superviseur qui tue
le processus TURN toutes les 120 secondes, puis le redémarre. **Une connexion
relayée peut être interrompue/reconnectée à cet intervalle.** Le direct n'est pas
touché. La réservation couvre les deux sens et l'intervalle d'authentification plus
un cycle de vie ; les limites `max-bps`, `user-quota` et le cycle doivent rester
alignés avec le coordinateur. Le quota épuisé refuse de nouveaux identifiants sans
couper la signalisation directe. La garantie monétaire vient du forfait sans
dépassement, pas d'une estimation d'octets. Avant service public, vérifier réellement
l'arrêt des allocations et le comportement après reconnexion ; tester un quota
réseau dur côté hébergeur, y compris les en-têtes et le trafic non TURN.

Le proxy masque les IP d'origine ; la limitation par adresse du coordinateur est
donc un plafond collectif de connexion derrière ce proxy. Les limites par socket,
paire et allocations restent applicables. Pour une installation plus chargée,
adapter ce plafond avec une transmission d'adresse authentifiée, sans faire
confiance à un en-tête libre fourni par le client.

Une seule instance peut ouvrir le fichier d'état : verrou exclusif `.lock`, écritures
atomiques suivies de `fsync` fichier et répertoire. Une panne d'écriture arrête les
autorisations et rend la santé indisponible. Après un arrêt brutal, vérifier qu'aucun
ancien processus ne tourne, sauvegarder l'état, puis retirer uniquement son verrou
orphelin avant redémarrage. Ne jamais supprimer l'état pour débloquer un démarrage :
il contient les révocations et réservations. Copier l'état à l'arrêt, conserver les
secrets séparément ; tester la restauration sur une installation isolée.

## Licences

Le code AIM est MIT. `ws` est MIT (`WS-LICENSE.txt`). Les images coturn et HAProxy
gardent leurs licences et dépendances propres ; consulter leurs sources officielles
avant redistribution. La bibliothèque Apple libdatachannel et ses notices se trouvent
dans `packages/AIMDirectNative/THIRD_PARTY_NOTICES` ; elle n'est pas relicenciée MIT.

Références : [coturn et TURN REST](https://github.com/coturn/coturn),
[libdatachannel](https://github.com/paullouisageneau/libdatachannel),
[HAProxy](https://docs.haproxy.org/3.2/configuration.html).

### Versions et modifications de permissions

Les clients du candidat 52 envoient un état de permissions signé lors de la
reconnexion. Le coordinateur doit inclure le traitement `grant` de cette version
avant de connecter ces clients par Internet. Cette mise à jour authentifie le Mac,
préserve les appareils et l'appairage, enregistre la nouvelle révision puis transmet
les signaux portant cette révision. Elle n'autorise aucune modification par l'iPhone.
La connexion locale reste indépendante du coordinateur. Le parcours Supabase
historique est distinct et ne change pas.
