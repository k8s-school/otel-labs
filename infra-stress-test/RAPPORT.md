# Session à 8 + bureaux Guacamole — 2026-09-13

Serveur **GP1-L** (32 vCPU, 128 Gio, volume racine 300 Go), image `flavor=otel`
du 2026-09-12, `make provision FLAVOR=otel NB_USERS=8` : 9 comptes
(`student1`–`student8` + `trainer`), clusters **pré-créés** par `precreate`
(vagues de 4), puis les labs rejoués sur les 9 comptes en parallèle **avec les
9 bureaux Guacamole ouverts** (client WebSocket + un Firefox/Grafana par
bureau) — ce qui manquait à la campagne du 12/09, ci-dessous.

## Verdict

**La salle à 8 tient, bureaux compris, avec de la marge** : 65 Gio sur 128 en
fin de parcours, 0 IOPS de lecture en régime établi, UIs à moins de 15 ms.
**Deux nouveaux thrashers**, absents de la liste du 12/09 : `flagd` (a saturé
le disque juste après le lab 1 ; limite relevée dans
`manifests/values-training.yaml`) et `kindnetd`, le CNI de kind (après le
stress mémoire ; limite relevée par `up.sh`). Le stress mémoire, qui avait
coûté 40 min de récupération et 14 OOM kills le 12/09, passe désormais en 4 min
sans aucun OOM kill.

## Chronologie

| Étape | Durée | Pic | Résultat |
|---|---|---|---|
| `make up` + `configure` | 3 min + 3 min | — | `ok=75 changed=42 failed=0`. L'étape `dns` échoue sans `OVH_*` dans l'environnement : sans conséquence, l'enregistrement existait déjà. |
| `precreate` (3 vagues de 4) | **20 min** | 1 400 IOPS, disque 43 % | 9/9 OK, 185 Go de disque (≈ 20 Go par cluster avec ses images) |
| Lab 1 `up.sh` + `open-ui.sh` ×9 | **300–320 s** | load 321, CPU idle 2 % | 9/9 exit=0, 27/27 pods partout. Contre 925–1643 s le 12/09 sans pré-création. |
| Lab 2 `deploy.sh` ×9 | **102–109 s** | load 103, RAM 58 Gio | 9/9 exit=0, 28/28 pods, +7 Go de disque |
| Lab 6 `generate-reviews.sh 600` ×9 | 604 s | — | 9/9 exit=0, 221 avis, 0 échec par compte |
| Lab 8 ×9 | 125 s | — | 9/9 exit=0 ; timeouts Jaeger attendus (agent inactif après `deploy.sh`) |

## Le défaut : `flagd` thrashe aussi

Trois minutes après la fin du lab 1, disque à **5 000 IOPS** (sa limite),
io_wait 47 %, PSI IO `some` 95 %, load 306. `thrash-scan.sh` : un `flagd` à
74/75 Mi avec **57 000 refaults/s**, `topio.sh` : 362 Mo/s lus par ce seul
processus. Le chart le plafonne à 75 Mi avec `GOMEMLIMIT=60MiB` : le tas Go
tient, mais pas les pages du binaire mappé.

`fix-thrash.sh "^/flagd-build" 200M` : PSI IO de 95 % à 4,6 % en vingt secondes,
lecture de 175 Mo/s à 1 Mo/s. Correctif durable : `flagd: 75Mi → 200Mi` dans le
values (conteneur `flagd` seul, pas le sidecar `flagd-ui`), poussé sur les 9
clusters par `apply-limits.sh flagd 75Mi 200Mi flagd`. Plus aucun refault
ensuite, y compris sous les labs 2, 6 et 8.

## Chiffres

### Lab 6 en régime établi (10 min, 9 stacks + load generators + 9 bureaux)

| Mesure | Valeur |
|---|---|
| RAM utilisée | 63 Gio moyenne, 65 max (sur 125) |
| CPU | 55 % occupé en moyenne (idle 44,7 %), load moyen 43, max 80 |
| Disque | 0 r/s, ~760 w/s (37 Mo/s, l'écriture continue des stacks) ; io_wait 6,6 % moy, 16 max |
| Latence Grafana / Jaeger / review-service | 6–13 ms / 6–10 ms / 80–195 ms |

Le load est plus haut que le ~6 noté le 12/09 : cette fois les 9 Firefox et le
client Guacamole tournaient, et la mesure a été prise pendant la rafale de
`generate-reviews.sh`. La contrainte reste le disque, jamais le CPU.

### Les bureaux Guacamole, mesurés cette fois

| Mesure | Valeur |
|---|---|
| RAM par bureau (PSS, XFCE + Firefox sur Grafana) | **0,81 Gio** (trainer : 2,9, il porte aussi le reste) |
| CPU guacd, 9 sessions | 6–17 % d'un vCPU au total, soit < 2 % par bureau |
| CPU Xorg ×9 / Firefox ×9 | 4 % / 12 % |
| Flux encodé | ~0,7 Mo/min par bureau (Guacamole n'envoie que les zones qui changent) |
| Tomcat Guacamole | 1,25 Gio, une seule fois |

Le coût d'un bureau, c'est le Firefox ; guacd est négligeable. L'estimation de
1,5 Gio par participant de la note était prudente.

### Par participant (`sizing-report.sh`, fin de parcours)

**8,45 Gio de stack + 1,10 Gio de bureau = 9,55 Gio**, soit ~84 Gio pour 11.
Disque : 196 Go utilisés sur 270 après tous les labs, ≈ 21 Go par participant ;
à 11 il resterait ~30 Go, et chaque `deploy.sh` en ajoute ~0,8.

### Stress tests (9 stacks + 9 bureaux en place)

| Test | Résultat | Lecture |
|---|---|---|
| **fio 4k aléatoire 70/30** | 2951 lecture + 1266 écriture IOPS, p99 0,1 ms | ~4 200 IOPS mixtes disponibles à côté des stacks, comme le 12/09 |
| **fio 1M séquentiel** | 1011 Mo/s | le débit brut n'est pas le sujet |
| **CPU, 32 workers, 3 min** | load 111, idle 0,9 %, PSI CPU 63 % ; Grafana 14–38 ms, Jaeger 14–35 ms, review-service 80–220 ms | le service reste rendu |
| **rebuild, 2 × 9 `deploy.sh`** | ~40 s par tour (cache Maven chaud), +2 Mio par participant | sans changement de code, le jar produit la même couche ; une vraie modification ajoute la sienne (quelques dizaines de Mo) |
| **RAM, 80 % du disponible (~44 Gio), 3 min** | load **1334** au pic, **0 OOM kill** (14 le 12/09), **retour au calme en 4 min** (40 le 12/09) | voir ci-dessous |
| **Dérive, 95 min sans rien faire** | RAM 65 → 69 Gio, disque +1 Go, CPU ~50 % (load generators + Grafana des bureaux) | pas de fuite visible sur cette durée |

**Le stress mémoire, cette fois.** Aucun OOM kill : les limites relevées donnent
aux services de quoi encaisser l'éviction de leur page cache. Un seul thrasher
est apparu après coup, **`kindnetd`** — le CNI de kind, plafonné à 50 Mi par
kind lui-même (DaemonSet `kube-system/kindnet`), exactement son working set :
~2 000 refaults/s par nœud, 4 nœuds sur 9, disque à 30 % seulement. Il ne se
résorbait pas seul ; `fix-thrash.sh "^/bin/kindnetd" 100M` l'a éteint sur le
champ. Correctif durable : `up.sh` relève la limite du DaemonSet à 100 Mi
après la création du cluster (idempotent), appliqué aux 9 clusters.

## À retenir pour la séance

- **Pré-créer les clusters** (`make provision` le fait) : le lab 1 passe de
  25 min à 5 min à 9 en parallèle.
- **Modale « Welcome to Firefox »** (conditions d'utilisation) au premier
  lancement sur chaque bureau : les stagiaires la verront. Une politique
  Firefox (`policies.json` : `SkipTermsOfUse`, `OverrideFirstRunPage`) dans
  l'image k8s-server l'éviterait.
- `make provision` a besoin des trois `OVH_*` dans l'environnement pour l'étape
  `dns`, sinon elle échoue et `configure`/`precreate` ne sont pas lancés.

## Ce qui a été corrigé dans les scripts

- `guac-load.py` : le parseur ne décodait aucune instruction (`i += 1` sur la
  ligne du `if … raise`), donc aucun `sync` renvoyé et guacd cessait d'envoyer
  des frames — la charge Guacamole du 12/09 n'aurait pas pu marcher non plus.
- `desktops.sh` : `sudo -i bash -lc '… $PF_HOST'` expansait `PF_HOST` à vide (le
  shell de login ré-interprète la commande), les Firefox partaient sur
  `http://:8080`. Sans `-i`.
- `phase.sh`, `stress.sh`, `desktops.sh` : le clone est `~/otel-labs`, plus
  `~/otel`.
- `apply-limits.sh` : 4e argument optionnel = conteneur (`flagd` a un sidecar).
- `scripts/up.sh` : limite mémoire du DaemonSet `kindnet` relevée à 100 Mi.

---

# Simulation d'une session à 9 + stress tests — 2026-09-12

Serveur **GP1-L** (32 vCPU, 128 Gio, volume racine `sbs_5k` 300 Go), image
`flavor=otel`, 9 stacks (`student1`–`student8` + `trainer`), bureaux Guacamole
provisionnés. But : vérifier que la salle tient, et pousser jusqu'à la casse
pour connaître les marges. Scripts et mode d'emploi dans [README.md](README.md).

## Verdict

**La machine tient une session à 9, avec une grande marge — une fois corrigé
un défaut de la démo qui n'apparaît pas sur un laptop.** En régime établi, les
9 stacks + load generators tiennent dans ~63 Gio sur 128, la latence des UIs
est de l'ordre de la milliseconde, le disque est quasi au repos. Le
dimensionnement de `NOTE-dimensionnement-serveur.md` est confirmé, et même
plutôt prudent : **~7 Gio par participant mesurés, contre 8,5 budgétés**.

Le défaut trouvé n'est pas une question de taille de machine : plusieurs
services de la démo sont plafonnés si bas en mémoire qu'ils **relisent leur
propre binaire depuis le disque en boucle** (*thrashing*). Invisible sur le
NVMe d'un laptop ; sur 9 stacks partageant un volume à 5 000 IOPS, cela suffit
à saturer le disque et à rendre les serveurs d'API injoignables. Corrigé par
des limites mémoire relevées dans `manifests/values-training.yaml`.

## Ce qui a été rejoué

| Phase | Ce qui tourne | Résultat |
|---|---|---|
| **Lab 1** (`up.sh -c` ×9 en parallèle) | 9 × `kind load` de ~5 Go simultanés | tous les clusters montés, **925 s à 1643 s** (médiane ~1466 s). C'est le pic d'I/O attendu : lancés ensemble, les 9 `kind load` mettent 25 min. **À faire par vagues, ou pré-créer avant l'arrivée.** |
| **Lab 2** (`deploy.sh` ×9) | 9 builds Maven + `kind load` de l'image | **88 s à 96 s**, sans accroc. Le cache de layers partagé (daemon Docker commun) fait que `mvn package` ne dure que ~18 s. Pic CPU load ~127, jamais la contrainte. |
| **Lab 6** (`generate-reviews.sh` ×9, 10 min) | trafic d'avis soutenu | régime établi, aucune saturation **après** correction des limites. |
| **Lab 8** (POST fautif + 30 GET + Jaeger/OpenSearch ×9) | requêtes de bout en bout | fonctionne ; les timeouts Jaeger sont normaux (l'agent Java est inactif après un `deploy.sh` par défaut). |

## Le défaut : thrashing mémoire des petits services Go/.NET

**Mécanisme.** Un conteneur collé à sa limite mémoire voit le cgroup évincer en
continu les pages *propres* de son exécutable mappé en mémoire. Le processus les
relit aussitôt depuis le disque. Sur un laptop NVMe c'est gratuit ; ici, chaque
pod concerné lisait **100 à 375 Mo/s**, et 9 pods identiques saturaient les
5 000 IOPS du volume. Conséquence en cascade : le disque saturé ralentit
l'etcd/API server de chaque kind, `kubectl` tombe en `connection reset by peer`,
et **Guacamole devient inutilisable** (guacd n'a plus d'I/O) — c'est ce qui a
été observé en séance pendant le test.

**Services pris en flagrant délit** (limite du chart → relevée) :

| Service | Techno | Limite chart | Relevée à | Niveau |
|---|---|---|---|---|
| `accounting` | .NET | 120 Mi | 300 Mi | conteneur |
| `checkout` | Go | 20 Mi | 100 Mi | conteneur |
| `product-catalog` | Go | 20 Mi | 96 Mi | conteneur |
| `shipping` | Go | 20 Mi | 96 Mi | conteneur |
| `currency` | Go | 20 Mi | 96 Mi | conteneur |
| `frontend-proxy` | envoy | **65 Mi (au pod)** | 200 Mi | **pod** |

`frontend-proxy` est le cas piégeux : sa limite est posée au niveau du **pod**,
pas du conteneur. Relever le conteneur seul ne sert à rien — d'où le script
`fix-pod-thrash.sh` qui relève les deux.

**Correctif durable** : ces six limites sont désormais dans
`manifests/values-training.yaml` (bloc `components:`), donc `up.sh` les applique
à la création. Le repérage se fait avec `thrash-scan.sh` (taux de *refault* par
conteneur) ; le remède à chaud, quand l'API server ne répond plus, avec
`fix-thrash.sh` / `fix-pod-thrash.sh` (écriture directe dans les cgroups) ;
l'application en masse sur des clusters déjà debout avec `apply-limits.sh`.

**Après correction** : `thrash-scan.sh` ne trouve plus **aucun** conteneur en
thrashing sous charge, disque à **0 IOPS de lecture** en régime, load ~6.

## Chiffres

### Régime établi, 9 stacks + load generators, limites corrigées

| Mesure | Valeur |
|---|---|
| RAM par participant (stack + bureau) | **6,97 Gio** (6,76 stack + 0,21 bureau) |
| Extrapolé à 11 (10 + trainer) | **~62 Gio** sur 128 |
| Load average | ~6 sur 32 vCPU |
| Disque en lecture | ~0 IOPS |
| Latence Grafana / Jaeger / review-service | ~5 ms / <1 ms / ~30 ms |

Le trafic navigateur du load generator (Playwright/Chromium, activé par défaut)
coûte à lui seul **~0,44 Gio et ~19 % d'un vCPU par stack** — mesuré, pas
négligeable, mais absorbé.

### Stress tests

| Test | Résultat | Lecture |
|---|---|---|
| **fio 4k aléatoire 70/30** | 3012 lecture + 1293 écriture IOPS, p99 0,1 ms | le volume tient ~4 300 IOPS mixtes à côté des stacks |
| **fio 1M séquentiel** | 1005 Mo/s en écriture | le débit brut n'est pas le souci, c'est l'IOPS aléatoire |
| **CPU, 32 workers, 3 min** | UIs toujours < 90 ms | les 32 vCPU saturés ne coupent pas le service |
| **RAM, 80 % du dispo, 3 min** | **14 OOM kills**, récupération **très lente** (>40 min) | voir ci-dessous |

**Le stress mémoire est le vrai enseignement.** Manger 58 Gio d'un coup a
déclenché l'OOM killer (product-catalog ×16, accounting ×7, checkout ×6…), et
surtout mis la machine dans une **spirale de thrashing** : les pods tués
redémarrent à leur petite limite, thrashent sur un disque déjà saturé, se font
retuer. La sortie de spirale a demandé de **couper les load generators** (baisser
la demande) et de **relever les limites en boucle** pour couvrir les
redémarrages — plus de 40 min pour revenir au calme. Enseignement : sur ce
serveur, la RAM n'est jamais la contrainte (63 sur 128 Gio), mais **le disque
l'est dès qu'un service thrashe**. Les limites corrigées suppriment la cause.

## Limites de ce test

- **Les bureaux Guacamole n'ont pas été chargés pour de vrai.** Le client de
  charge WebSocket (`guac-load.py`) et la génération du fichier de comptes
  (`make-accounts.sh`, qui lit le vault) ont été **bloqués par les garde-fous de
  l'agent** (accès aux mots de passe). Le coût du bureau reste donc l'estimation
  de la note (~1,5 Gio/participant), non mesurée. À refaire à la main : lancer
  `guac-load.py` depuis le poste formateur avec un `accounts.txt` généré
  localement. Le PSS des vraies sessions XFCE, lui, est mesurable avec
  `desktops.sh list` une fois les bureaux ouverts.
- **Un seul cycle**, pas deux jours : la question de la dérive de la stack sur la
  durée (Prometheus/OpenSearch/Jaeger qui accumulent) reste ouverte. `monitor.sh`
  tourne en continu et alimente `monitor.csv` pour y répondre en laissant le
  serveur vivre quelques heures.

## Suites à donner

1. **Commiter les limites** ajoutées à `manifests/values-training.yaml` (fait le défaut disparaît pour de bon, y compris sur laptop où il est inoffensif).
2. **Lab 1 par vagues** de 3–4, ou pré-création des clusters — déjà recommandé par la note, confirmé (25 min à 9 en parallèle).
3. Refaire la **mesure des bureaux Guacamole** à la main, seul chiffre encore estimé.
4. Ne pas oublier **`make down FLAVOR=otel`** en fin de campagne (le serveur est facturé).
