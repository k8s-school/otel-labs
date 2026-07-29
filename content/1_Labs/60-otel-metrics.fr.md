---
title: 'Lab 6 — Métriques métier'
date: 2026-07-06T11:40:00+02:00
draft: false
weight: 60
tags: ["OpenTelemetry", "métriques", "Micrometer", "Prometheus"]
---

Le Lab 3 collectait des métriques d'**infrastructure** (système, PostgreSQL) ; le connector spanmetrics fournit déjà débit et latence par service. Il manque les métriques **métier** : combien d'avis créés ? En combien de temps ? Dans ce lab, vous instrumentez `review-service` avec **Micrometer** (un compteur + un histogramme), exportés vers Prometheus via l'agent OpenTelemetry, puis vous dérivez une métrique depuis les spans avec le connector **`count`**.

## Prérequis

* Labs 1 à 3 terminés, agent Java actif sur `review-service` (cf. Lab 5, étape 2).
* Port-forward Prometheus : `kubectl port-forward -n otel-demo svc/prometheus 9090:9090 &`
* Le port local du review-service dans `$APP_PORT` (accès **direct**, pas via le frontend-proxy). Sourcez `scripts/env.sh` en début de session : `. ./scripts/env.sh` définit `APP_PORT=8090+PORT_OFFSET` (`8090` en solo, `809<N>` sur le serveur partagé).

## Étapes

### Partie 1 — Compteur et histogramme dans le code

1.  **Lire l'instrumentation Micrometer** dans `apps/review-service/src/main/java/fr/k8sschool/reviews/ReviewController.java` :

```java
this.reviewsCreated = Counter.builder("reviews.created")
        .description("Number of product reviews created")
        .register(registry);
this.reviewCreationTimer = Timer.builder("reviews.creation.time")
        .description("Time spent creating a review (catalog check + insert)")
        .publishPercentileHistogram()
        .register(registry);
```

Pourquoi **Micrometer** plutôt que le SDK OpenTelemetry directement ?

{{%expand "Réponse" %}}
Les deux marchent. Micrometer est la **façade métriques standard de Spring** (fournie par Actuator, déjà dans le classpath) : l'équipe de dev n'apprend pas une nouvelle API, et le code reste neutre. L'**agent OpenTelemetry fait le pont automatiquement** : chaque meter Micrometer devient une métrique OTLP.

⚠️ Le bridge Micrometer de l'agent est **désactivé par défaut** (pour éviter les doublons avec les métriques Spring) : c'est le rôle de `OTEL_INSTRUMENTATION_MICROMETER_ENABLED=true` à l'étape suivante. Sans lui, vos meters restent invisibles — un classique du debug OTel.

L'alternative SDK pur : injecter un `Meter` OTel (`meter.counterBuilder("reviews.created").build()`) — même résultat, API OTel native. Les deux instruments du programme sont là :
* `Counter` → **compteur** (monotone croissant) ;
* `Timer` + `publishPercentileHistogram()` → **histogramme** de latence (buckets → percentiles calculables côté Prometheus). Une **jauge** (3ᵉ type) serait par ex. `Gauge.builder("reviews.pending", queue::size)`.
{{% /expand%}}

2.  **Déployer et générer du trafic :**

```bash
./scripts/deploy.sh
kubectl set env -n otel-demo deployment/review-service \
  JAVA_TOOL_OPTIONS="-javaagent:/otel/opentelemetry-javaagent.jar" \
  OTEL_INSTRUMENTATION_MICROMETER_ENABLED=true
kubectl rollout status -n otel-demo deployment/review-service

kubectl port-forward -n otel-demo svc/review-service $APP_PORT:8080 &
for i in $(seq 1 10); do
  curl -s -X POST http://localhost:$APP_PORT/api/reviews \
    -H "Content-Type: application/json" \
    -d "{\"productId\": \"OLJCESPC7Z\", \"rating\": $((RANDOM % 5 + 1)), \"comment\": \"avis $i\", \"userEmail\": \"user$i@example.com\", \"userName\": \"User $i\"}" > /dev/null
done
```

3.  **Retrouver les métriques dans Prometheus** ([http://localhost:9090](http://localhost:9090)) :

* `reviews_created_total` — votre compteur ;
* `reviews_creation_time_*` — votre histogramme (`_bucket`, `_sum`, `_count`).

Tracez la latence p95 de création d'un avis :

{{%expand "Réponse" %}}
```promql
histogram_quantile(0.95, sum(rate(reviews_creation_time_seconds_bucket[2m])) by (le))
```

Chemin parcouru : Micrometer → bridge de l'agent → OTLP → collecteur → exporter `otlphttp/prometheus` → Prometheus. Les noms sont traduits par la convention OpenTelemetry → Prometheus (`reviews.created` → `reviews_created_total`).
{{% /expand%}}

### Partie 2 — Dériver une métrique depuis les spans (connector `count`)

4.  **Ajouter le connector `count`** : comme au Lab 3, un fichier de values, `manifests/60-otel-metrics-values.yaml`. Il doit compter les spans **en erreur** et exposer le résultat en métrique `app.spans.errors`.

{{%expand "Réponse" %}}
Le fichier de référence est [`60-otel-metrics-values.yaml`](../60-otel-metrics-values.yaml). Pour l'utiliser tel quel :

```bash
cp content/1_Labs/60-otel-metrics-values.yaml manifests/
```

Son contenu :

```yaml
opentelemetry-collector:
  config:
    connectors:
      count:
        spans:
          app.spans.errors:
            description: "Number of spans with ERROR status"
            conditions:
              - status.code == STATUS_CODE_ERROR
    processors:
      deltatocumulative: {}
    service:
      pipelines:
        traces:
          exporters: [otlp/jaeger, debug, spanmetrics, count]
        metrics:
          receivers: [otlp, kafkametrics, spanmetrics, hostmetrics, postgresql, count]
          processors: [memory_limiter, resourcedetection, resource, deltatocumulative, batch]
```

Un **connector** est à la fois *exporter* d'un pipeline (traces) et *receiver* d'un autre (metrics) — les deux listes doivent le référencer.

Et pourquoi `deltatocumulative` ? Le connector `count` émet ses métriques en temporalité **delta** (chaque export = l'incrément depuis le précédent), or l'endpoint OTLP de Prometheus n'accepte que du **cumulatif** — sans ce processor, il répond HTTP 500 et le collecteur jette les points (`Exporting failed. Dropping data.` dans ses logs, exercice de debug classique).
{{% /expand%}}

```bash
helm upgrade otel-demo open-telemetry/opentelemetry-demo \
  --version 0.40.9 -n otel-demo \
  -f manifests/values-training.yaml \
  -f manifests/30-otel-collector-values.yaml \
  -f manifests/60-otel-metrics-values.yaml
kubectl rollout status daemonset/otel-collector-agent -n otel-demo
```

5.  **Provoquer des erreurs et vérifier :** créez un avis pour un produit inexistant (le service échoue en 500) :

```bash
curl -s -X POST http://localhost:$APP_PORT/api/reviews \
  -H "Content-Type: application/json" \
  -d '{"productId": "DOESNOTEXIST", "rating": 5, "comment": "?", "userEmail": "x@example.com", "userName": "X"}'
```

Dans Prometheus, cherchez `app_spans_errors_total` : votre première métrique **dérivée des traces**, sans une ligne de code.

## Livrable

Dans Grafana ou Prometheus : le graphe de latence p95 (`reviews_creation_time`) + le compteur métier `reviews_created_total` + la métrique dérivée `app_spans_errors_total`.
