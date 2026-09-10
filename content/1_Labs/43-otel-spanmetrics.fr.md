---
title: 'Lab 4 bonus — Le dashboard spanmetrics de la démo'
date: 2026-09-09T23:00:00+02:00
draft: false
weight: 43
tags: ["spanmetrics", "Prometheus", "Grafana", "RED"]
---

Page de lecture : rien à construire, rien à déployer. La démo livre un dashboard bâti sur les métriques `traces_span_metrics_*`, celles que le collecteur fabrique à partir des traces. Il donne le trio **RED** — *Rate, Errors, Duration* — pour tous les services d'un coup, et il éclaire au passage un piège que le dashboard du Lab 4 évite sans le dire.

## Prérequis

* Lab 4 terminé, les accès ouverts (`./scripts/open-ui.sh`), les variables chargées (`. ./scripts/env.sh`).

## 1. `span_kind`, en une minute

Chaque span porte une étiquette `span_kind` qui dit **quel bout de l'appel il mesure**. Cinq valeurs, toutes présentes dans la démo :

| `span_kind` | Le span mesure… | Vu dans la démo |
|---|---|---|
| `SPAN_KIND_SERVER` | une requête **reçue** (HTTP, gRPC) | `GET /api/reviews` du `review-service` |
| `SPAN_KIND_CLIENT` | un appel **émis** vers un autre service ou une base | le `SELECT` envoyé à PostgreSQL |
| `SPAN_KIND_INTERNAL` | un traitement **interne**, ni entrant ni sortant | `HikariDataSource.getConnection` |
| `SPAN_KIND_PRODUCER` | un message **déposé** dans une file | `publish orders`, chez `checkout` |
| `SPAN_KIND_CONSUMER` | un message **lu** dans une file | `receive orders`, chez `accounting` |

Pour les lister sur votre cluster, dans *Explore* :

```promql
count by (span_kind) (traces_span_metrics_calls_total)
```

`SERVER` et `CONSUMER` sont les deux formes de **travail entrant** : ce sont elles qui correspondent à « une requête que ce service a traitée ». Les trois autres décrivent ce qui se passe *à l'intérieur* de ce traitement, ou ce qu'il déclenche ailleurs.

> 💡 `span_kind` dit quel bout de l'appel un span mesure, **pas** sa profondeur dans l'arbre.

## 2. Le piège : une requête n'est pas un span

Un `GET /api/reviews` de votre `review-service` produit **trois** spans :

```text
GET /api/reviews                 kind = server     ← la requête entière
HikariDataSource.getConnection   kind = internal   ← dedans
SELECT otel                      kind = client     ← dedans
```

Une requête, vue à trois niveaux de détail. Mais `spanmetrics` les chronomètre séparément et les verse dans le **même** histogramme : les deux tiers de spans quasi instantanés tirent la distribution vers le bas. Mesuré sous charge sur le cluster de la formation :

| Requête | p95 affiché |
|---|---|
| sans filtre | **6,6 ms** |
| `span_kind="SPAN_KIND_SERVER"` | **22,9 ms** |

Sans filtre, le chiffre annoncé comme un p95 suit en réalité le p85 des requêtes — et il se déplace si l'instrumentation change, l'agent Java du Lab 2 produisant cinq spans par requête au lieu de trois. Même service, même latence réelle, chiffre différent.

D'où le filtre du dashboard du Lab 4 :

```promql
histogram_quantile(0.95, sum(rate(traces_span_metrics_duration_milliseconds_bucket{
  service_name=~"$service_name", span_kind=~"SPAN_KIND_SERVER|SPAN_KIND_CONSUMER"}[2m])) by (le, span_kind))
```

Le filtre ne retient que le **travail entrant**, `SERVER` et `CONSUMER`. Les deux sont nécessaires : `accounting` et `fraud-detection` ne sont jamais appelés en HTTP, ils consomment du Kafka, et le filtre `SERVER` seul laisse leur panel vide.

## 3. Le dashboard que la démo livre

Ouvrez **« Spanmetrics Demo Dashboard »** :

```bash
echo "http://$PF_HOST:$UI_PORT/grafana/d/W2gX2zHVk48"
```

Il affiche les trois signaux RED, et surtout il ajoute une variable que le Lab 4 n'avait pas : **`span_name`**. Sélectionnez une opération précise et les latences cessent d'être un mélange — c'est la parade au piège ci-dessus, prise par l'autre bout.

Trois panels à regarder :

* **Top 7 Services Mean Rate** — le débit, service par service ;
* **Top 7 Services Mean ERROR Rate** — le même compteur filtré sur `status_code="STATUS_CODE_ERROR"` ;
* **Top 3x3 - Service Latency** — le p95, groupé `by (le, service_name)`.

> 💡 Une seule requête est active par panel, les autres sont masquées (`hide`) : ce sont des variantes prêtes à l'emploi pour basculer d'un quantile à l'autre. Regardez-les dans l'éditeur, pas dans la légende.

Ce dashboard n'applique aucun filtre `span_kind` : vous savez maintenant ce que ses latences valent tant qu'on ne choisit pas de `span_name`.
