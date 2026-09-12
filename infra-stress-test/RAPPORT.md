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
