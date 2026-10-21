# Proposition d’hébergement Direct — 17 octobre 2026

**Recommandation conditionnelle : OVHcloud VPS-1, gamme 2027, dans un datacenter européen, avec Linux sans licence payante.** Le prix public observé est **à partir de 3,81 € HT / 4,57 € TTC par mois**, IPv4 et trafic inclus. Ce document prépare un choix ; il ne constitue ni un bon de commande, ni un prix de renouvellement garanti, ni une autorisation de dépense. Aucun compte, panier, paiement ou déploiement n’a été créé. Aucun champ `reviewedBy` n’a été rempli.

## Offre concrète observée

Sources officielles consultées le **17 octobre 2026**, boutique française :

| Poste | Observation | Réserve |
| --- | --- | --- |
| VPS-1 2027 | 2 vCores, 4 Go de RAM, 40 Go NVMe ; tarif d’appel 3,81 € HT / 4,57 € TTC par mois ; débit public 500 Mbit/s | Le prix est annoncé « à partir de ». Disponibilité et montant final non vérifiés dans un panier. |
| IPv4 | Une adresse dédiée figure parmi les éléments inclus | Ne pas ajouter d’Additional IP payante. |
| Trafic | Illimité annoncé pour cette offre en Europe | Débit fini ; ne pas assimiler trafic illimité et capacité illimitée. |
| Sauvegarde | Sauvegarde quotidienne des dernières 24 heures annoncée incluse | Aucune option Premium, snapshot ou stockage supplémentaire retenue. |

Ces éléments proviennent de la [fiche VPS OVHcloud France](https://www.ovhcloud.com/fr/vps/). Le [billet officiel de présentation de la gamme 2027](https://blog.ovhcloud.com/fr/posts/vps-2027/) confirme l’inclusion des deux familles IP. Le dimensionnement convient comme **candidat à tester** pour un coordinateur léger et son relais ; aucune mesure de charge n’a qualifié cette capacité pour AIM.

## Engagement, paiement initial et renouvellement

Le lien « Configurer » de VPS-1 pointe vers ce [configurateur officiel](https://www.ovhcloud.com/fr/vps/configurator/?brick=VPS%2BModel%2B1&planCode=vps-2027-model1&pricing=upfront12&processor=+&storage=40__SSD__NVMe&vcore=2__vCore), avec le paramètre **`pricing=upfront12`**. Cela signale une formule de paiement anticipé sur 12 mois ; le récapitulatif interactif n’a pas été obtenu dans la consultation publique. **Le tarif de 4,57 € TTC ne doit donc pas être annoncé comme une offre mensuelle sans engagement.**

À titre de calcul, 3,81 × 12 = 45,72 € HT, soit environ **54,86 € TTC à 20 %** avant les éventuels arrondis du fournisseur. Le montant TTC mensuel affiché est arrondi ; le multiplier par 12 ne donne pas nécessairement la facture annuelle. Un paiement anticipé dépasse 20 € le mois du règlement, même si son équivalent mensuel est inférieur au plafond.

Le prix mensuel sans engagement, les frais de mise en service éventuels, la fin d’une éventuelle promotion et le tarif du renouvellement n’ont **pas été confirmés** par un récapitulatif officiel. Aucun tarif de comparateur n’est substitué à cette preuve. Le propriétaire doit vérifier ces quatre points avant de choisir la durée. Si 20 € est aussi une limite de décaissement mensuel, retenir uniquement une facturation mensuelle réellement proposée sous ce montant ; sinon ne pas commander.

OVHcloud indique que les services sont **en renouvellement automatique par défaut**. Le passage au renouvellement manuel est prévu pour les VPS éligibles ; ce changement doit être vérifié personnellement après souscription. Un moyen de paiement absent n’équivaut pas à une résiliation. Le manuel peut entraîner suspension puis suppression du service si le renouvellement n’est pas payé. [Guide officiel de renouvellement](https://docs.ovhcloud.com/fr/guides/account-and-service-management/managing-billing-payments-and-services/automatic-renewal).

## Trafic, dépassements et recharges

La [page officielle des VPS à trafic illimité](https://www.ovhcloud.com/fr/vps/unmetered-vps/) présente une tarification fixe sans facturation au volume ni frais de dépassement. Elle précise une exception pour Mumbai, Singapour et Sydney : quota mensuel puis débit réduit. **La proposition retient l’Europe**, sans option réseau payante.

C’est une base commerciale favorable à un relais TURN, mais pas une certification de toutes les conditions contractuelles du service choisi. Avant achat, conserver le récapitulatif et les conditions VPS effectivement applicables, accessibles depuis la [liste officielle des contrats](https://www.ovhcloud.com/fr/terms-and-conditions/contracts/). Vérifier que l’usage TURN/proxy envisagé est autorisé et connaître les possibilités de limitation ou suspension pour usage abusif. Aucune garantie de débit ou d’absence de suspension n’est ajoutée ici.

Aucune preuve n’a été recueillie dans un compte concernant un réglage de recharge automatique. L’offre décrite ne présente pas de mécanisme de recharge au Go ; cela ne permet pas de certifier tous les réglages futurs du compte. **Absence de dépassement facturé, absence de recharge automatique et renouvellement automatique de l’abonnement sont trois points distincts.** Ne pas activer d’option, montée en gamme, crédit ou service à la consommation. Le contrôle financier doit couvrir tout le trafic du VPS, y compris la signalisation, et pas seulement le compteur applicatif TURN.

## Domaine : supplément seulement si nécessaire

Si le propriétaire contrôle déjà un domaine et sa zone DNS, deux sous-domaines peuvent servir au coordinateur et au relais. Aucun nouveau nom n’est nécessaire dans ce cas ; **le coût de renouvellement du domaine existant reste à compter** si le plafond vise toute l’infrastructure. Aucun domaine existant n’a été inspecté ou reconfiguré.

Sinon, un `.fr` ordinaire disponible et éligible est une possibilité, sans choix de nom effectué : OVHcloud affiche **5,99 € TTC la première année**, puis **9,35 € TTC/an au renouvellement**, soit environ **0,78 €/mois** à provisionner au tarif de renouvellement. La page comporte aussi une offre multi-année ; elle n’est pas retenue comme économie garantie. Source : [tarifs officiels .fr, création et renouvellement](https://www.ovhcloud.com/fr/domains/tld/fr/).

Au seul prix VPS d’appel affiché, le calcul indicatif avec cette provision de domaine est **4,57 + 9,35 / 12 ≈ 5,35 € TTC/mois équivalent**. Ce n’est pas un total mensuel de commande vérifié. Les deux noms DNS doivent être couverts par un certificat valide ; aucun certificat commercial n’est inclus dans le chiffrage. Tout achat ou option supplémentaire doit être ajouté avant de comparer au plafond de 20 €.

## Choix à faire par le propriétaire

Avant toute commande :

1. Choisir VPS-1 en Europe, Linux sans licence payante, une seule IPv4 incluse, sans service additionnel ; vérifier le stock.
2. Relever le prix TTC initial, la durée engagée, le calendrier de paiement, les frais et le prix de renouvellement. Vérifier la TVA de son pays ; les montants ci-dessus sont ceux affichés par la boutique française.
3. Ajouter le domaine réellement retenu et tout autre poste obligatoire. Exiger un total récurrent et un renouvellement **≤ 20 € TTC/mois** ; vérifier séparément la limite de paiement initial.
4. Vérifier les conditions de trafic et l’absence de dépassement payant/recharge ; choisir personnellement le mode de renouvellement et ses conséquences.
5. Seulement après cette revue, renseigner le devis privé AIM avec son propre nom de relecteur, la date de validité et les pièces justificatives. Un « trafic illimité » ne doit pas être converti arbitrairement en nombre d’octets contractuellement inclus dans un JSON.

Le devis privé reste **non approuvé**. La disponibilité publique du relais exige aussi les vérifications TLS, permissions des volumes, arrêt effectif du relais aux limites, révocation et essais réseau réels. Un tarif bas ne prouve aucune de ces propriétés techniques.
