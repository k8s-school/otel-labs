---
title: 'Lab 4 — Dashboard unifié logs / métriques / traces'
date: 2026-07-06T16:55:00+02:00
draft: false
weight: 40
tags: ["Grafana", "dashboard", "Prometheus", "OpenSearch", "Jaeger"]
---

Vous disposez maintenant des trois signaux : traces (Labs 2), métriques système et produit (Lab 3), logs (collectés d'office par la démo). Dans ce lab, vous les rassemblez dans **un seul dashboard Grafana** : la « vue service » que consulterait un astreinte.

## Prérequis

* Labs 1 à 3 terminés.
* Le port-forward des UIs actif (`./scripts/open-ui.sh`) — Grafana sur [http://localhost:8080/grafana/](http://localhost:8080/grafana/) (`808<N>` sur serveur partagé).

## Étapes

1.  **Explorer les datasources déjà câblées :**

Dans Grafana : ⚙️ *Connections → Data sources*. Trois sources correspondent à nos trois signaux — identifiez-les et notez leur type.

{{%expand "Réponse" %}}
| Datasource | Type | Signal | Backend |
|---|---|---|---|
| **Prometheus** (`webstore-metrics`) | prometheus | métriques | `http://prometheus:9090` |
| **Jaeger** (`webstore-traces`) | jaeger | traces | `http://jaeger:16686` |
| **OpenSearch** (`webstore-logs`) | grafana-opensearch-datasource | logs | index `otel-logs-*` |

Le chart Helm de la démo les provisionne automatiquement (ConfigMap `grafana-datasources`). Remarquez dans la config de Prometheus les **exemplars** : un lien direct métrique → trace.
{{% /expand%}}

2.  **Créer un dashboard vide** (*Dashboards → New → New dashboard*), puis **ajouter la variable `service_name`** :

*Settings → Variables → New variable* :
* Type `Query`, datasource **Prometheus**
* Query : `label_values(calls_total, service_name)`

> `calls_total` est produite par le connector **spanmetrics** du collecteur (vu au Lab 3) : chaque service tracé a donc automatiquement des métriques de débit/latence — y compris `review-service`, sans l'avoir instrumenté pour les métriques !

3.  **Panel 1 — métriques (Prometheus) :** un *Time series* « Débit de requêtes » :

```promql
sum(rate(calls_total{service_name=~"$service_name"}[2m]))
```

Ajoutez un second panel « Latence p95 » :

```promql
histogram_quantile(0.95, sum(rate(duration_milliseconds_bucket{service_name=~"$service_name"}[2m])) by (le))
```

4.  **Panel 2 — logs (OpenSearch) :** un panel de type *Logs*, datasource **OpenSearch**, requête Lucene :

```text
resource.service.name:"$service_name"
```

5.  **Panel 3 — traces (Jaeger) :** un panel *Table* (ou *Traces*), datasource **Jaeger**, query type *Search*, service `$service_name`, limit 20.

6.  **Tester la variable :** basculez `service_name` entre `frontend`, `checkout` et `review-service` — les trois panels doivent suivre.

7.  **Exporter le dashboard en JSON** (*Share → Export → Save to file*) : c'est le **livrable**, à committer dans votre dépôt.

{{%expand "Réponse (dashboard complet)" %}}
Le dashboard de référence est [`40-otel-grafana-dashboard.json`](../40-otel-grafana-dashboard.json). Pour l'importer : *Dashboards → New → Import* et coller le JSON, ou par l'API :

```bash
curl -sS -X POST http://localhost:8080/grafana/api/dashboards/db \
  -H "Content-Type: application/json" \
  -d "{\"overwrite\": true, \"dashboard\": $(cat content/1_Labs/40-otel-grafana-dashboard.json)}"
```
{{% /expand%}}

8.  **Bonus — une règle d'alerte :** *Alerting → New alert rule* sur la latence p95 de `$service_name` (> 500 ms pendant 2 min). Observez l'état `Pending` → `Firing` en chargeant la boutique via le load generator.

## Livrable

Le dashboard « vue service » exporté en JSON, avec ses 3 panels pilotés par la variable `service_name`.
