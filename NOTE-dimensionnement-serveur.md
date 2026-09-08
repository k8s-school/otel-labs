# Dimensionnement du serveur de formation

*Ouverte le 2026-09-03 pour une session à 12. Réécrite le 2026-09-08 sur des
mesures, pour la session Michelin à 10 participants.*

## Ce que coûte une stack, mesuré

Mesuré le 2026-09-08 sur un cluster kind local complet — les 28 pods de la démo
`otel-demo`, le load generator **et** le review-service du lab 2 déployé — sur
dix échantillons de `docker stats` étalés sur quatre minutes de régime :

| Ressource | Mesure | Budget retenu |
|---|---|---|
| RAM | 6,47 Gio (bande 6,32 à 6,60) | **7 Gio** |
| CPU en régime | 0,89 vCPU (bande 0,37 à 1,48) | **0,9 vCPU** |
| CPU en pic | 4,1 vCPU pendant le `docker build` du lab 2 | — |
| Disque | 20 Go (`/var/lib/containerd` : 19 Go, 46 images) | **20 Go** |

**La stack oscille avec un cycle d'environ 40 secondes**, apparu quand le
review-service s'est mis à recevoir du trafic : la RAM va et vient sur 280 Mio,
le CPU entre 0,37 et 1,48 vCPU. Échantillonner toutes les 20 secondes verrouille
l'échantillonnage sur une phase et donne 0,4 ou 1,4 selon celle qu'on attrape.
Une première série, prise juste après le déploiement du review-service, avait
ainsi conclu à 0,46 vCPU — c'était le creux du cycle, pas la moyenne. Les
chiffres ci-dessus moyennent douze échantillons sur quatre minutes.

Il faut donc mesurer sur plusieurs minutes, et se méfier de tout relevé pris à
intervalle régulier proche d'un diviseur de 40 secondes.

Le disque du nœud kind vit dans un **volume Docker** monté sur `/var`, pas dans
la couche du conteneur : `docker ps -s` affiche 3 Mo et ment. C'est
`du -sh` sur le volume qui donne les 20 Go.

### Les deux chiffres que cette note portait à tort

La version du 2026-09-03 reprenait les valeurs de `group_vars/otel.yml` :

* **disque : 11 Go annoncés, 20 Go réels.** C'est l'erreur qui compte : elle
  sous-estime de moitié la ressource qui sature en premier.
* **CPU : 1,7 vCPU annoncés, 0,89 réel.** Environ deux fois moins, pas quatre —
  onze stacks demandent une dizaine de vCPU en régime, une quinzaine avec
  Guacamole. Ce n'est pas la contrainte sur un GP1-L, mais ça l'aurait été sur
  les 16 vCPU d'un GP1-M.

Le commentaire de sizing en tête de `group_vars/otel.yml` porte encore ces
chiffres et reste à corriger.

## Le total pour 10 participants

Onze stacks : dix participants plus le compte `trainer`. À la stack s'ajoute le
bureau Guacamole — le mode par défaut est `rdp`, donc un XFCE et un Firefox par
personne, estimés à 1,5 Gio (pas mesuré ici). Soit **8,5 Gio et 21 Go par
participant**.

| | 11 stacks | Base système | Total |
|---|---|---|---|
| RAM | 94 Gio | ~6 Gio (OS, Docker, Guacamole, guacd) | **100 Gio** |
| RAM en pic | +10 à 20 Gio transitoires | | **~115 Gio** |
| Disque | 231 Go | ~23 Go (OS ; images partagées : démo ~5 Go, maven/temurin ~1,5 Go) | **~255 Go** |
| CPU en régime | 9,8 vCPU | ~2 vCPU (guacd encode dix flux RDP) | **~12 vCPU** |

Le pic de RAM est celui du lab 2 : dix `docker build` multi-stage lancés
ensemble, donc dix JVM Maven. C'est lui qui interdit de descendre à 96 Gio.

## La machine : GP1-L, disque 300 Go

Prix relevés le 2026-09-08 sur `fr-par-1` (`scw instance server-type list`) :

| Type | vCPU | RAM | €/h | Verdict |
|---|---|---|---|---|
| GP1-M (actuel) | 16 | 64 Gio | 0,384 | RAM insuffisante : il en faut 100 |
| POP2-HM-12C-96G | 12 | 96 Gio | 0,618 | aucune marge sur le pic du lab 2 |
| **GP1-L** | **32** | **128 Gio** | **0,774** | **retenu** |
| POP2-HM-16C-128G | 16 | 128 Gio | 0,824 | plus cher, et moitié moins de vCPU |

À RAM égale le GP1-L est moins cher que le POP2-HM, avec deux fois plus de
vCPU — ce sont eux qui absorbent les dix builds simultanés. Les 96 Gio
économiseraient 7 € sur la session pour une marge nulle : non retenu.

### Coût horaire

| Poste | €/h |
|---|---|
| GP1-L | 0,774 |
| Disque 300 Go (`sbs_5k` à 0,00013 €/Go/h) | 0,039 |
| **Total** | **0,813 €/h HT** |

Soit **39 € pour 48 h** — le serveur provisionné la veille et détruit le
lendemain. La configuration actuelle (GP1-M + 100 Go) coûte 0,397 €/h, donc
19 € : la décision se paie **20 €**, pour dix personnes.

L'IP réservée est facturée en continu, que le serveur tourne ou non
(`prevent_destroy` dans `tofu/main.tf`) : elle n'entre pas dans le surcoût.

Éteindre la nuit sans détruire économise environ 9 € de compute — le disque
reste facturé — pour le risque de rallumer un serveur en salle le matin. Non
recommandé sur deux jours.

## Un seul serveur, pas deux

Deux GP1-M de cinq participants coûtent 0,768 €/h, exactement le prix du
GP1-L. Le gain est nul et le coût opérationnel réel : l'IP réservée de
`tofu/main.tf` porte un tag unique sous `prevent_destroy` et le tfvars ne
déclare qu'un `dns_subdomain`. Deux serveurs, c'est deux provisionnements, deux
URLs Guacamole à distribuer et deux `make configure` — qui coupent les bureaux
des participants à chaque passage.

## Les limites de l'hôte Linux : déjà couvertes

C'est le piège attendu avec onze clusters kind sur une machine, et le
provisioning le traite déjà. `roles/guacamole/tasks/desktop.yml:437` pose
`fs.inotify.max_user_instances = 8192` et `max_user_watches = 1048576`, et
`site.yml:18` explique que le rôle passe tôt, avant que les clusters n'épuisent
inotify.

Vérifié sur le cluster de mesure, extrapolé à onze :

| Limite | Par cluster | × 11 | Plafond | |
|---|---|---|---|---|
| instances inotify | 44 | ~500 | 8 192 | large |
| threads | 2 612 | ~29 000 | `TasksMax=infinity` (docker, containerd) | ok |
| conntrack | 1 231 | ~14 000 | 262 144 | large |
| clés keyring | — | — | root : 1 M clés / 25 Mo | ok |

Le keyring mérite une précision : les 200 clés par uid visibles dans
`/proc/key-users` ne s'appliquent pas, parce que les nœuds kind sont des
conteneurs de dockerd et tournent donc sous root, dont le quota est à 1 M.
Rien à ajouter côté sysctl.

## Le vrai risque : les I/O, pas la RAM

Ce qui reste à surveiller n'est pas une limite noyau mais le disque au **lab 1** :
dix `up.sh` lancés ensemble, c'est dix fois 5 à 6 Go de `kind load` sur un
volume à 5 000 IOPS. Faire démarrer les clusters par vagues de trois ou quatre,
ou les pré-créer avant l'arrivée des participants.

Au **lab 2**, une optimisation gratuite : lancer un `./scripts/deploy.sh` sous
le compte `trainer` avant la session. Le daemon Docker est partagé par tous les
participants (`extra_groups: ["docker"]` dans `group_vars/otel.yml`), donc ce
premier build peuple le cache de layers et les dix suivants n'ont plus à
télécharger les dépendances Maven en parallèle.

## La stack du formateur

Elle tourne sans problème sur le laptop (22 vCPU, 62 Gio, 240 Go libres) : c'est
d'ailleurs là qu'ont été prises les mesures ci-dessus.

Garder malgré tout le compte `trainer` sur le serveur. Il est déjà prévu par le
provisioning, il ne coûte que les 8,5 Gio comptés plus haut, et démontrer depuis
un environnement identique à celui des participants — mêmes `PF_ADDR`, même
Firefox, mêmes chemins — évite les « chez moi ça marche ». Le laptop pour
préparer et répéter, le compte `trainer` pour la salle.

## Ce qui est appliqué

Appliqué le 2026-09-08 dans `../k8s-server/provisioning` :

* `tofu/envs/otel-large.tfvars` (l'ancien `otel.tfvars`, renommé) : `GP1-L` et
  `root_volume_size_gb = 300`.
* `tofu/envs/otel-small.tfvars`, **nouveau** : le même environnement sur un
  GP1-S (8 vCPU / 32 Gio / 100 Go, 0,191 €/h), pour répéter les labs seul.
* `ansible/group_vars/otel.yml` : `nb_users` de 20 à 12, et le commentaire de
  sizing corrigé.
* `Makefile` : un axe `SIZE=`, orthogonal à `FLAVOR=`. Il sélectionne le tfvars
  et rien d'autre — l'image, les `group_vars` et l'inventaire continuent de
  suivre `FLAVOR`, donc une variante de taille est le *même* environnement sur
  une machine d'une autre taille. Plus `NB_USERS=<N>`, qui surcharge l'effectif
  pour le seul `make configure`.
* `util/sizing-report.sh`, **nouveau** : le rapport à lancer sur le serveur, qui
  mesure ce que coûte réellement un participant, stack et bureau ensemble.

Le flavor `otel` n'a plus de tfvars sans suffixe et vaut `large` par défaut :

```bash
make provision FLAVOR=otel                          # la session : GP1-L, 12 comptes
make provision FLAVOR=otel SIZE=small NB_USERS=2    # la répétition : GP1-S, 2 comptes
```

Les deux variantes partagent un state OpenTofu, une IP réservée et un
enregistrement DNS : **une seule existe à la fois**. Changer de taille impose
donc `make down` puis `make up SIZE=…` — appliquer par-dessus un serveur vivant
demanderait à Scaleway de changer le type *et* de redimensionner le volume
racine en place, ce qu'il refuse.

## Valider la taille avant la formation

Deux inconnues justifient de louer le GP1-L une demi-journée avant la session,
pour 4 € :

**Le bureau Guacamole n'est pas mesuré.** Les 1,5 Gio par participant (XFCE,
xrdp, Firefox) sont une estimation, le seul chiffre du tableau qui ne vienne pas
d'un relevé. Il pèse 16 Gio sur les 100 : s'il est deux fois plus gros, la marge
du GP1-L fond.

**On ne sait pas si la stack dérive sur deux jours.** Elle est passée de 6,1 à
6,5 Gio en une heure, mais l'essentiel s'explique par le review-service qui
monte en charge, pas par une fuite : rien ne permet de conclure à une dérive sur
une heure d'observation. Prometheus, OpenSearch et Jaeger accumulent pourtant
bien des données pendant deux jours. Le budget de 7 Gio couvre la bande mesurée
avec 6 % de marge, ce qui est mince si elle se déplace. Une machine laissée
tourner une demi-journée avec onze stacks tranche la question.

**Prérequis : il n'existe aucune image `flavor=otel` sur le compte Scaleway.**
`scw instance image list` n'en montre qu'une, taguée `flavor=k8s`. `make up`
refuse de démarrer sans image et n'a pas de distro de repli :

```bash
cd ../k8s-server/provisioning
make create-image FLAVOR=otel            # ~15 min, une seule fois
make provision FLAVOR=otel               # GP1-L, 12 comptes (SIZE=large par défaut)
```

Puis, sur le serveur, créer les onze stacks sans attendre dix personnes :

```bash
for u in trainer student1 student2 student3 student4 student5 \
         student6 student7 student8 student9 student10; do
    sudo -u "$u" -i bash -lc './otel/scripts/up.sh -p' &
done; wait
```

Les lancer toutes en parallèle est volontaire : c'est exactement le pic d'I/O du
lab 1, et le seul moyen de savoir s'il faut faire démarrer la salle par vagues.

Enfin, ouvrir deux ou trois bureaux par Guacamole, dérouler un lab jusqu'au
review-service, et lancer :

```bash
./util/sizing-report.sh
```

Il donne la RAM par stack, le PSS par bureau — en PSS et non en RSS, sinon les
bibliothèques partagées par dix Firefox seraient comptées dix fois — le coût
d'un participant, et l'extrapolation à onze. Le relancer après quelques heures
répond à la question de la croissance.

Si le total extrapolé dépasse 115 Gio, le cran suivant est le GP1-XL (48 vCPU /
256 Gio, 1,674 €/h) : il double la facture, à 80 € pour la session.

Ne pas oublier `make down` à la fin du test — sinon la machine est facturée
jusqu'au jour J.
