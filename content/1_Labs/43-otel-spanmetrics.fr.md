---
title: "Lab 4 bonus — spanmetrics : une requête n'est pas un span"
date: 2026-09-09T23:00:00+02:00
draft: false
weight: 43
tags: ["spanmetrics", "Prometheus", "Grafana", "RED"]
---

Page de lecture : rien à construire, rien à déployer. Une requête produit plusieurs spans, et `spanmetrics` les chronomètre un par un : additionner leurs seaux donne un chiffre qui ne décrit aucune requête réelle. Cette page mesure l'écart sur le cluster, puis ouvre le dashboard que la démo livre — le trio **RED** — *Rate, Errors, Duration* — pour tous les services à la fois.

## Prérequis

* Lab 4 terminé, les accès ouverts (`./scripts/open-ui.sh`), les variables chargées (`. ./scripts/env.sh`).

## 1. Le piège : une requête n'est pas un span

Un `GET /api/reviews` de votre `review-service` produit **trois** spans — vous les avez comptés dans Jaeger au Lab 2 :

```text
GET /api/reviews                 ← la requête entière
HikariDataSource.getConnection   ← dedans
SELECT otel                      ← dedans
```

Une requête, vue à trois niveaux de détail. Mais `spanmetrics` les chronomètre **séparément**, et si on additionne leurs seaux, les deux tiers de spans quasi instantanés tirent la distribution vers le bas. Le chiffre obtenu reste un p95 — mais celui des **spans**, pas celui des **requêtes**.

Mesuré sur le `frontend` du cluster de la formation, qui compte 39 opérations :

| Ce qu'on calcule | p95 |
|---|---|
| tous les spans additionnés | 196 ms |
| l'opération `GET /api/recommendations` | 199 ms |
| l'opération `POST /api/checkout` | **1 921 ms** |

Les 196 ms ne décrivent aucune requête réelle : elles sont tirées vers le bas par les dizaines d'opérations rapides du service, et elles cachent complètement le passage de commande, huit fois plus lent. Ce n'est pas non plus « un centile un peu plus bas » qu'on pourrait corriger d'un facteur : l'écart dépend du nombre de spans que produit chaque requête, donc de l'instrumentation — l'agent Java du Lab 2 en génère cinq là où le starter en génère trois.

D'où la forme du panel du Lab 4 :

```promql
topk(5, histogram_quantile(0.95, sum(rate(traces_span_metrics_duration_milliseconds_bucket{
  service_name=~"$service_name", span_name=~"$span_name"}[2m])) by (le, span_name)))
```

Le `by (le, span_name)` fait le tri à la source : les seaux d'opérations différentes ne sont **jamais** additionnés, donc aucune moyenne ne se forme entre un `SELECT` d'une milliseconde et une commande de deux secondes. Chaque courbe est le p95 d'**une** opération, et le `topk(5)` garde à l'écran les cinq plus lentes — celles qu'on cherche.

## 2. Le dashboard que la démo livre

Ouvrez **« Spanmetrics Demo Dashboard »** :

```bash
echo "http://$PF_HOST:$UI_PORT/grafana/d/W2gX2zHVk48"
```

Il affiche les trois signaux RED pour **tous** les services à la fois, là où le dashboard du Lab 4 en regarde un seul. Sa variable `span_name` existe aussi — mais ses panels groupent `by (le, service_name)`, pas `by (le, span_name)` : tant qu'on laisse l'opération sur *All*, les latences affichées **sont** le mélange décrit ci-dessus, les 196 ms du `frontend` et non les 1 921 ms de son passage de commande. Sélectionnez une opération, et le chiffre redevient exact.

Trois panels à regarder :

* **Top 7 Services Mean Rate** — le débit, service par service ;
* **Top 7 Services Mean ERROR Rate** — le même compteur filtré sur `status_code="STATUS_CODE_ERROR"` ;
* **Top 3x3 - Service Latency** — le p95, groupé `by (le, service_name)`.

> 💡 Une seule requête est active par panel, les autres sont masquées (`hide`) : ce sont des variantes prêtes à l'emploi pour basculer d'un quantile à l'autre. Regardez-les dans l'éditeur, pas dans la légende.

C'est la même parade que celle du Lab 4, prise par l'autre bout : là où votre panel sépare les opérations d'office, celui-ci attend que vous en désigniez une.
