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

Le chart Helm de la démo les provisionne automatiquement (ConfigMap `grafana-datasources`). Ouvrez la configuration de Prometheus : elle contient un bloc `exemplars` qui la relie à Jaeger — c'est le sujet de l'étape 9.

Retenez l'**UID** : c'est par lui qu'un panel désigne sa datasource, et non par son nom d'affichage. Le dashboard de référence de l'étape 5 contient `"datasource": { "type": "prometheus", "uid": "webstore-metrics" }` — c'est ce qui lui permet de s'importer sans re-câbler un seul panel. Un dashboard récupéré ailleurs (grafana.com, un autre cluster) porte d'autres UID : ses panels arrivent vides tant qu'on ne les a pas repointés.
{{% /expand%}}

> 💡 **Où lire l'UID d'une datasource ?** Deux chemins, l'un pour la souris, l'autre pour un script.
>
> Dans l'interface, ouvrez la datasource : l'UID est **dans l'URL**, en dernier segment — `.../grafana/connections/datasources/edit/webstore-metrics`.
>
> En ligne de commande (la démo autorise l'accès anonyme avec le rôle Admin : aucun jeton à créer) :
>
> ```bash
> . ./scripts/env.sh   # si ce n'est pas déjà fait dans ce terminal
>
> # les UID des trois datasources
> curl -s http://$PF_HOST:$UI_PORT/grafana/api/datasources | grep -o '"uid":"[^"]*"'
>
> # celui d'une datasource précise, par son nom d'affichage
> curl -s http://$PF_HOST:$UI_PORT/grafana/api/datasources/name/Prometheus | grep -o '"uid":"[^"]*"'
> ```
>
> Cette même API montre l'UID à l'œuvre **entre** datasources. La configuration d'une datasource se lit dans le champ `jsonData` de la réponse ; isolons-en une ligne, celle de Prometheus :
>
> ```bash
> curl -s http://$PF_HOST:$UI_PORT/grafana/api/datasources/name/Prometheus \
>   | grep -o '"exemplarTraceIdDestinations":\[[^]]*\]'
> ```
>
> ```json
> "exemplarTraceIdDestinations":[{"datasourceUid":"webstore-traces","name":"trace_id"}, ...]
> ```
>
> Traduction : « quand tu rencontres un `trace_id`, va ouvrir la trace dans la datasource dont l'UID est `webstore-traces` » — c'est-à-dire Jaeger. Sans cet UID, Grafana saurait qu'il tient un identifiant de trace, mais pas où aller la chercher. C'est le mécanisme des **exemplars**, à l'étape 9.
>
> La même configuration se lit à deux autres endroits : dans l'interface, sur la page de la datasource Prometheus ; et à la source, dans la ConfigMap qui la provisionne — `kubectl get configmap grafana-datasources -n otel-demo -o yaml`.

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

9.  **Bonus (avancé) — les exemplars : du point sur la courbe à la trace.**

Une métrique est une **agrégation** : « 30 requêtes, p95 à 400 ms » ne dit pas *quelles* requêtes. Un **exemplar** est une mesure individuelle conservée à côté de l'agrégat, avec le `trace_id` de la requête qui l'a produite :

```text
série    : http_client_duration_milliseconds_bucket{service_name="load-generator", net_peer_name="flagd"}
exemplar : value = 6 (ms)   labels = {trace_id: "114a5fc9…", span_id: "2b9ec640…"}
```

Grafana pose alors de petits marqueurs sur la courbe de latence : cliquer sur l'un d'eux ouvre **la trace de cette requête précise**, celle qui a fait le pic. Au lieu de chercher dans Jaeger une trace qui ressemblerait au symptôme, c'est le symptôme qui vous donne son identifiant.

Essayez dans *Explore*, datasource **Prometheus**, en activant les exemplars dans les options de la requête :

```promql
histogram_quantile(0.95, sum(rate(http_client_duration_milliseconds_bucket[5m])) by (le))
```

{{%expand "Pourquoi ça marche ici — et pas sur vos panels" %}}
Il faut réunir trois conditions ; les deux premières sont remplies par la démo :

* **Prometheus stocke les exemplars** — il est démarré avec `--enable-feature=exemplar-storage` (visible dans `/api/v1/status/flags`) ; sans ce drapeau, il les jette à l'ingestion ;
* **la datasource sait où ouvrir la trace** — c'est le `"exemplarTraceIdDestinations": [{"datasourceUid": "webstore-traces"}]` de l'étape 1 : l'UID de Jaeger, et rien d'autre, fait le lien ;
* **la métrique doit en porter** — et c'est là que ça coince pour le dashboard que vous venez de construire.

Les métriques `traces_span_metrics_*` du connector `spanmetrics` n'ont **aucun** exemplar : sa configuration `{}` ne les produit pas (il faut le lui demander explicitement). Ceux de la démo viennent des **SDK des applications**, sur `http_client_duration_milliseconds_bucket` et `rpc_server_duration_milliseconds_bucket`.

Vous pouvez le constater par l'API, sans Grafana :

```bash
. ./scripts/env.sh   # si ce n'est pas déjà fait dans ce terminal
kubectl port-forward -n otel-demo --address $PF_ADDR svc/prometheus $PROM_PORT:9090 &

curl -s -G "http://$PF_HOST:$PROM_PORT/api/v1/query_exemplars" \
  --data-urlencode 'query=http_client_duration_milliseconds_bucket' \
  --data-urlencode "start=$(date -d '-1 hour' +%s)" --data-urlencode "end=$(date +%s)" \
  | head -c 400
```

Remplacez le nom par `traces_span_metrics_duration_milliseconds_bucket` : la réponse est `{"status":"success","data":[]}`.
{{% /expand%}}

> 💡 **Et pour en avoir sur *vos* panels ?** `spanmetrics` sait produire des exemplars — il faut simplement le lui demander, l'option étant désactivée par défaut. Sur le modèle du Lab 3, créez `manifests/40-otel-grafana-values.yaml` :
>
> ```yaml
> opentelemetry-collector:
>   config:
>     connectors:
>       spanmetrics:
>         exemplars:
>           enabled: true
> ```
>
> puis empilez-le sur les values des labs précédents :
>
> ```bash
> helm upgrade otel-demo open-telemetry/opentelemetry-demo \
>   --version 0.40.9 -n otel-demo \
>   -f manifests/values-training.yaml \
>   -f manifests/30-otel-collector-values.yaml \
>   -f manifests/40-otel-grafana-values.yaml
> kubectl rollout status daemonset/otel-collector-agent -n otel-demo
> ```
>
> Deux minutes plus tard, `calls_total` **et** l'histogramme de latence portent leurs exemplars — et votre panel « Latence p95 » devient cliquable jusqu'à la trace. C'est le `{}` de la configuration par défaut qui vous en privait, pas une limite du connector.
>
> Deux réserves à connaître : un exemplar n'est gardé **que le temps d'un cycle d'export** (il n'est pas rejoué indéfiniment), et `max_per_data_point` en limite le nombre à 5 par point de mesure.

## Livrable

Le dashboard « vue service » exporté en JSON, avec ses 3 panels pilotés par la variable `service_name`.
