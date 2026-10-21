# Recherche hybride : configuration et qualification

Le réglage existant reste **Provider-hosted search**. Aucun passage silencieux à
Exa ou Brave : l'utilisateur choisit explicitement **Research mode** dans la
configuration Chat iPhone ou Settings → Work sur Mac, puis enregistre sa propre
**Search API key**. L'enregistrement ne lance aucune recherche. La clé va dans
le trousseau du profil actif, jamais dans les préférences exportées ou les journaux.

L'orchestration AIM est actuellement disponible en **Chat**, avec une route
Anthropic ou OpenRouter acceptant les outils. Agent, Code, modèle incompatible,
clé absente ou budget strict incompatible produisent un refus avant recherche,
sans autre fournisseur de secours. Les outils web hébergés ne sont pas ajoutés
en parallèle. L'iPhone exécute son Chat natif ; une conversation sur Mac utilise
les clés et le réseau du Mac, sans copier les clés sur l'iPhone.

Chaque tour est borné à quatre recherches non mises en cache et six pages lues.
Le modèle ne peut demander que des identifiants de résultats réellement retournés.
Les lectures sont HTTPS publiques, sans JavaScript, cookie ou connexion à un site ;
elles acceptent actuellement HTML/texte UTF-8. Les contenus restent des données
non fiables. Les résultats, pages lues et citations sont des notions distinctes.
Les répétitions réutilisent le cache du tour ; pas de cache entre deux profils.

La facture du modèle et les frais du moteur ont des lignes distinctes. Un montant
confirmé n'est jamais ajouté une seconde fois comme estimation. Un reçu absent
reste inconnu ; un tarif daté reste une estimation et expire après trente jours.
Les protections strictes continuent de refuser les plafonds non vérifiables.
Les explications de coût se trouvent dans les réglages et les informations de
réponse, sans avertissement permanent au-dessus de la saisie.

## Comparaison à effectuer avant toute recommandation

Les tests actuels des adaptateurs sont synthétiques. Aucun appel Exa/Brave payant
n'a été effectué. Avant un essai réel, le propriétaire doit choisir son moteur,
sa clé dans l'app et un budget dédié ; l'autorisation OpenRouter de 5 $ ne vaut
pas autorisation d'acheter du crédit chez un autre fournisseur.

Sur un projet synthétique identique, poser les mêmes questions avec le même modèle :
une information récente vérifiable, une comparaison à deux sources et une page
détaillée nécessitant lecture. Tester d'abord le parcours hébergé, puis le moteur
AIM choisi. Relever réponse correcte, URLs/citations, lectures observées, délai et
coût complet (reçus modèle + recherche + éventuels tokens supplémentaires).
Tester annulation, quota atteint, clé refusée et coupure réseau sans réessai payant
automatique. Vérifier qu'une ancienne conversation reste lisible après relance.

Ne conclure « moins cher », « plus rapide » ou « meilleur » qu'après comparaison.
Les parcours hébergés peuvent ne fournir que des citations finales ; AIM ne crée
pas d'animation de sites prétendument visités lorsqu'aucun événement ne l'atteste.

Références des adaptateurs : [Exa](https://docs.exa.ai/reference/search),
[Brave Search](https://api-dashboard.search.brave.com/app/documentation/web-search/get-started),
[OpenRouter](https://openrouter.ai/docs/guides/features/server-tools/web-search).
