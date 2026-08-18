---
title: 'Lab 4 bonus — Lire un histogramme : p95 et heatmap'
date: 2026-08-18T10:30:00+02:00
draft: false
weight: 42
tags: ["Grafana", "PromQL", "histogramme", "heatmap", "Prometheus"]
---

Page de lecture : rien à construire, rien à déployer. Elle reprend les trois requêtes des Labs 4 et 4.1 et les ouvre en grand — d'où sort un p95, ce qu'il cache, et pourquoi la même métrique donne aussi une heatmap.

## 1. Le p95, mot à mot

```promql
histogram_quantile(0.95, sum(rate(traces_span_metrics_duration_milliseconds_bucket{service_name=~"$service_name"}[2m])) by (le))
```

**`_bucket` et `le`.** spanmetrics ne conserve pas la durée de chaque span — ce serait revenir aux traces. Il les **range dans des seaux** : `..._duration_milliseconds_bucket{le="100"}` compte les spans qui ont duré **100 ms ou moins** (`le` = *less or equal*). Ces seaux sont **cumulatifs** — un span de 30 ms incrémente aussi celui des 100 ms, celui des 500 ms, et ainsi de suite jusqu'à `le="+Inf"` qui les contient tous.

```text
..._bucket{le="10"}    = 120     ← 120 spans ont duré 10 ms ou moins
..._bucket{le="50"}    = 380       (les 120 précédents sont dedans)
..._bucket{le="100"}   = 450
..._bucket{le="500"}   = 495
..._bucket{le="+Inf"}  = 500     ← tous les spans
```

Ces cinq lignes se lisent : 500 spans observés, dont 450 sous 100 ms et 495 sous 500 ms. Or le p95, c'est la durée du **475e span** (95 % de 500) une fois triés du plus rapide au plus lent. Il tombe donc entre le 450e et le 495e, c'est-à-dire **entre 100 et 500 ms**. Sa valeur exacte, en revanche, n'est nulle part dans la métrique : elle ne retient que des **comptages par seau**, jamais les durées individuelles. Il faut donc la **reconstituer**.

*« Et pourquoi ne pas aller lire la durée du 475e span dans Jaeger, tout simplement ? »* Parce qu'il n'y est peut-être pas — au Lab 7, le tail sampling ne gardera qu'un quart des traces — et parce qu'un service réel produit des millions de spans par minute : les trier à chaque rafraîchissement du panel, sur six heures de fenêtre, n'est pas tenable. Les traces vivent d'ailleurs quelques jours, les métriques des mois. Chaque signal fait son métier : la métrique dit **qu'il y a** un problème et depuis quand, pour trois fois rien et sur la longue durée ; la trace dit **laquelle** des requêtes a souffert.

**Pourquoi des seaux plutôt que des durées.** Parce qu'**un percentile ne s'additionne pas**. La moyenne du p95 de deux pods n'est pas le p95 de l'ensemble, c'est un nombre sans signification. Des seaux, eux, s'additionnent sans difficulté : 120 spans sous 10 ms ici, 200 là, cela fait bien 320. On renonce donc aux durées exactes pour gagner le droit d'agréger, quitte à recalculer le percentile au moment de l'affichage.

**D'où la requête, lue de l'intérieur vers l'extérieur :**

* `rate(...[2m])` — chaque seau est un compteur cumulé **depuis le démarrage du collecteur**. Sans `rate`, le panel décrirait la distribution des latences *depuis toujours*, une courbe presque immobile où l'incident d'il y a trois heures pèse autant que la minute en cours ;
* `sum(...) by (le)` — réunit toutes les opérations et toutes les instances **en gardant le découpage par seau**. Un `sum` nu écraserait aussi `le` : il ne resterait plus de distribution à lire, et la fonction suivante renverrait `NaN` ;
* `histogram_quantile(0.95, ...)` — relit cette distribution et rend le seuil sous lequel tombent 95 % des spans, **en millisecondes** (le nom de la métrique le dit ; les métriques des SDK, elles, sont souvent en `_seconds`).

En une phrase : *sur les deux dernières minutes, 95 % des spans de ce service ont été plus rapides que la valeur affichée.*

## 2. Ce que ce p95 ne dit pas

**Sa précision est celle des seaux.** Reprenons le 475e span. Il se trouve dans le seau (100 → 500], qui en contient 45 (495 − 450). Il faut y avancer de 25 spans (475 − 450) sur ces 45, soit **55,6 %** du chemin — et `histogram_quantile` applique cette proportion à la **largeur** du seau :

```text
       seau de 400 ms de large, 45 spans dedans
  100 ms                    322 ms              500 ms
    |------------------------|-------------------|
  450e                     475e                 495e
    <------ 25 spans ------> <---- 20 spans ---->
              (55,6 %)

  100 + 0,556 × (500 - 100) = 322 ms
```

C'est cela, l'**interpolation linéaire** : on suppose les 45 spans espacés régulièrement entre les deux bornes, comme les graduations d'une règle. Or ils pourraient aussi bien être tous à 105 ms que tous à 495 ms — la réponse serait la même. L'erreur est donc bornée par la largeur du seau : « 322 ms » signifie surtout « entre 100 et 500 ». Seuls des seaux plus serrés améliorent la précision, et cela se règle à la production de la métrique, pas à la lecture.

**Attention au plateau.** Quand le centile dépasse la dernière borne finie, Prometheus ne renvoie pas `+Inf` mais [la borne supérieure de l'avant-dernier seau](https://prometheus.io/docs/prometheus/latest/querying/functions/#histogram_quantile). Si le plus grand seau est `le="15000"`, le panel affiche 15 000 ms : la latence *semble* plafonner à une valeur ronde, alors qu'en réalité elle est sortie de l'échelle de mesure. Les bornes réelles de votre cluster se listent en une requête, dans *Explore* — ne les déduisez pas de la documentation :

```promql
count by (le) (traces_span_metrics_duration_milliseconds_bucket{service_name="checkout"})
```

**Il mélange des opérations hétérogènes.** Tel quel, le panel confond un `GET /health` à 2 ms et un `PlaceOrder` à 800 ms. C'est le bon choix pour une vue d'ensemble du service, mais dès qu'on cherche *quoi* est lent, il faut détailler — un percentile par opération :

```promql
histogram_quantile(0.95, sum(rate(traces_span_metrics_duration_milliseconds_bucket{service_name=~"$service_name"}[2m])) by (le, span_name))
```

**Ce n'est pas la latence vue par vos utilisateurs.** Elle porte sur les spans arrivés au collecteur. Au Lab 7, le tail sampling n'en laissera passer qu'un quart : le percentile sera alors calculé sur un échantillon — et un échantillon biaisé, puisque le sampling retient précisément les erreurs et les requêtes lentes.

## 3. Le pic fantôme : pourquoi `rate` avant `sum`

Deux pods de collecteur, `A` et `B`, 2 requêtes/s chacun — donc **4 req/s en réalité**, stable. Scrape toutes les 15 s. `B` redémarre à t=45 s.

| t | A | rate(A) | B | rate(B) | **sum(rate)** ✅ | A+B | **rate(sum)** ❌ |
|---|---|---|---|---|---|---|---|
| 0 s | 1000 | — | 800 | — | — | 1800 | — |
| 15 s | 1030 | 2/s | 830 | 2/s | **4/s** | 1860 | **4/s** |
| 30 s | 1060 | 2/s | 860 | 2/s | **4/s** | 1920 | **4/s** |
| 45 s | 1090 | 2/s | **0** ⚡ | 0/s | **2/s** | **1090** | **≈ 73/s** 💥 |
| 60 s | 1120 | 2/s | 30 | 2/s | **4/s** | 1150 | **4/s** |

Les deux écritures donnent le même résultat partout, **sauf sur la ligne du redémarrage**.

À gauche, `rate` compare 0 à 860 sur la seule série de `B` : reset reconnu, delta ramené à 0 — le pod n'a effectivement rien compté pendant qu'il redémarrait. La courbe creuse à 2/s, ce qui est la vérité : la moitié de la capacité était absente.

À droite, la même comparaison se fait sur le total, 1090 contre 1920. Baisse, donc reset, donc delta = 1090 → `1090 / 15 ≈ 73/s`. Ce 1090, ce sont les **requêtes cumulées de `A` depuis son propre démarrage**, comptées d'un coup comme si elles venaient d'arriver en 15 secondes. Le pic n'est pas du trafic : c'est l'historique de `A` relâché sur un intervalle. Et plus `A` tourne depuis longtemps, pire c'est — à 50 000 au compteur, le faux pic monterait à 3 300/s.

Deux détails que le tableau simplifie : un vrai `rate[2m]` étale ce pic sur la fenêtre au lieu de le concentrer sur un point (plus bas, plus large, même erreur totale) ; et PromQL rend d'ailleurs la mauvaise écriture malaisée — `rate(sum(...)[2m])` est invalide, il faut une *subquery* pour y arriver.

## 4. La heatmap : la distribution entière

Le Lab 4.1 met côte à côte deux panels bâtis sur **la même métrique** :

```promql
# heatmap
sum by(le) (rate(app_cart_get_cart_latency_seconds_bucket[$__rate_interval]))

# p95
histogram_quantile(0.95, sum by(le) (rate(app_cart_get_cart_latency_seconds_bucket[$__rate_interval])))
```

La seconde est la première, résumée par `histogram_quantile`. Autrement dit : **le p95 est ce qui reste de la heatmap quand on n'en garde qu'une ligne par colonne.**

**Ce que la heatmap montre en plus.** Un p95 est un chiffre unique : il ne peut pas dire si les requêtes forment **une** population ou **deux**. Or c'est fréquent — une réponse servie depuis un cache et une réponse calculée n'ont pas la même durée, et l'histogramme le voit tout de suite :

```text
  le (s)
  0.5 |                                     ░░░░░░░░      ← quelques requêtes lentes
  0.1 |     ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓      ← 2ᵉ population : calcul complet
 0.05 |
 0.01 |     ████████████████████████████████████████      ← 1ʳᵉ population : réponse en cache
      +--------------------------------------------→ temps
```

Deux bandes horizontales bien nettes : deux comportements, pas un. Le p95 correspondant afficherait une courbe plate quelque part au-dessus de la bande du haut, sans jamais laisser deviner qu'il y en a deux. Et le jour où le cache se dégrade, la bande du bas maigrit **avant** que le p95 ne bouge vraiment : la heatmap est un signal d'alerte plus précoce, parce qu'elle voit se déplacer la masse et pas seulement sa queue.

**Quand utiliser l'une ou l'autre.**

| | Heatmap | Percentile |
|---|---|---|
| Répond à | « à quoi ressemble la distribution ? » | « ça va, ou pas ? » |
| Bon pour | comprendre, explorer un incident | suivre dans le temps, **alerter** |
| Faiblesse | dense, illisible sur une longue fenêtre ; aucun seuil à y poser | masque la forme de la distribution |

Une alerte a besoin d'un nombre unique à comparer à un seuil : c'est le p95, pas la heatmap. Mais quand l'alerte a sonné, c'est la heatmap qu'on regarde pour savoir **ce qui s'est déplacé**.

> 💡 Les cellules d'une heatmap Prometheus se colorent à partir des mêmes seaux `le` que le p95 : Grafana range les séries de la requête en lignes, une par borne, et compte ce qui est tombé dans chacune pendant l'intervalle. C'est visible dans *Panel → Inspect → Panel JSON*, à côté du `"exemplar": true` du Lab 4.1.
