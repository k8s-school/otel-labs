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
* **D'abord** les variables de la formation chargées dans votre shell : `. ./scripts/env.sh` — elles donnent `$PF_HOST` et `$UI_PORT`, l'adresse et le port de vos UIs.
* **Ensuite** le port-forward des UIs : `./scripts/open-ui.sh`. Le script affiche l'URL de Grafana, `http://$PF_HOST:$UI_PORT/grafana/` — soit `http://localhost:8080/grafana/` sur un poste individuel, mais `http://localhost3:8080/grafana/` pour student3 sur le serveur partagé.

## Étapes

1.  **Explorer les datasources déjà câblées :**

Dans Grafana : ⚙️ *Connections → Data sources*. Trois sources correspondent à nos trois signaux — identifiez-les et notez leur type.

{{%expand "Réponse" %}}
| Datasource | UID | Type | Signal | Backend |
|---|---|---|---|---|
| **Prometheus** | `webstore-metrics` | prometheus | métriques | `http://prometheus:9090` |
| **Jaeger** | `webstore-traces` | jaeger | traces | `http://jaeger:16686` |
| **OpenSearch** | `webstore-logs` | grafana-opensearch-datasource | logs | index `otel-logs-*` |

Le chart Helm de la démo les provisionne automatiquement (ConfigMap `grafana-datasources`). Remarquez dans la config de Prometheus les **exemplars** : un lien direct métrique → trace.

Retenez l'**UID** : c'est par lui qu'un panel désigne sa datasource, et non par son nom d'affichage. Le dashboard de référence de l'étape 5 contient `"datasource": { "type": "prometheus", "uid": "webstore-metrics" }` — c'est ce qui lui permet de s'importer sans re-câbler un seul panel. Un dashboard récupéré ailleurs (grafana.com, un autre cluster) porte d'autres UID : ses panels arrivent vides tant qu'on ne les a pas repointés.
{{% /expand%}}

> 💡 **Où lire l'UID d'une datasource ?** Deux chemins, l'un pour la souris, l'autre pour un script.
>
> Dans l'interface, ouvrez la datasource : l'UID est **dans l'URL**, en dernier segment — `.../grafana/connections/datasources/edit/webstore-metrics`.
>
> En ligne de commande (la démo autorise l'accès anonyme avec le rôle Admin : aucun jeton à créer) :
>
> ```bash
> # les UID des trois datasources
> curl -s http://$PF_HOST:$UI_PORT/grafana/api/datasources | grep -o '"uid":"[^"]*"'
>
> # celui d'une datasource précise, par son nom d'affichage
> curl -s http://$PF_HOST:$UI_PORT/grafana/api/datasources/name/Prometheus | grep -o '"uid":"[^"]*"'
> ```
>
> Cette même API montre l'UID à l'œuvre entre datasources : la configuration de Prometheus contient `"exemplarTraceIdDestinations": [{"datasourceUid": "webstore-traces", "name": "trace_id"}]`. C'est ce câblage — Prometheus → l'UID de Jaeger — qui fait qu'un exemplar sur un graphe de latence ouvre la trace correspondante.

2.  **Créer un dashboard vide** (*Dashboards → New → New dashboard*), puis **ajouter la variable `service_name`** :

*Settings → Variables → New variable* :
* Type `Query`, datasource **Prometheus**
* Query : `label_values(traces_span_metrics_calls_total, service_name)`

> `traces_span_metrics_calls_total` est produite par le connector **spanmetrics** du collecteur (vu au Lab 3) : chaque service tracé a donc automatiquement des métriques de débit/latence — y compris `review-service`, sans l'avoir instrumenté pour les métriques !

3.  **Panel 1 — métriques (Prometheus) :** un *Time series* « Débit de requêtes » :

```promql
sum(rate(traces_span_metrics_calls_total{service_name=~"$service_name"}[2m]))
```

Ajoutez un second panel « Latence p95 » :

```promql
histogram_quantile(0.95, sum(rate(traces_span_metrics_duration_milliseconds_bucket{service_name=~"$service_name"}[2m])) by (le))
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
. ./scripts/env.sh   # si ce n'est pas déjà fait dans ce terminal

curl -sS -X POST http://$PF_HOST:$UI_PORT/grafana/api/dashboards/db \
  -H "Content-Type: application/json" \
  -d "{\"overwrite\": true, \"dashboard\": $(cat content/1_Labs/40-otel-grafana-dashboard.json)}"
```
{{% /expand%}}

8.  **Bonus — une règle d'alerte :** *Alerting → New alert rule* sur la latence p95 de `$service_name` (> 500 ms pendant 2 min). Observez l'état `Pending` → `Firing` en chargeant la boutique via le load generator.

## Livrable

Le dashboard « vue service » exporté en JSON, avec ses 3 panels pilotés par la variable `service_name`.
