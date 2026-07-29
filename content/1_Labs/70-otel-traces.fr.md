---
title: 'Lab 7 — Traces manuelles & échantillonnage'
date: 2026-07-06T14:55:00+02:00
draft: false
weight: 70
tags: ["OpenTelemetry", "traces", "spans", "sampling", "baggage"]
---

L'instrumentation automatique (Lab 2) trace les frontières techniques (HTTP, SQL). Pour tracer la **logique métier**, on crée des spans manuels. Dans ce lab : un span manuel via annotation, la **propagation de contexte** vers un autre service, le **bagage**, puis la maîtrise du volume avec le **tail sampling**.

## Prérequis

* Labs 1 à 6 terminés, agent Java actif sur `review-service`.
* Port-forward UIs actif (`./scripts/open-ui.sh`).
* Le port local du review-service dans `$APP_PORT` (accès **direct**, pas via le frontend-proxy). Sourcez `scripts/env.sh` en début de session : `. ./scripts/env.sh` définit `APP_PORT=8090+PORT_OFFSET` (`8090` en solo, `809<N>` sur le serveur partagé).

## Étapes

### Partie 1 — Spans manuels & propagation

1.  **Lire l'instrumentation manuelle** dans `ProductCatalogClient.java` :

```java
@WithSpan("product-catalog.lookup")
public void checkProductExists(@SpanAttribute("app.product.id") String productId) {
    ...
    Span.current().setAttribute("app.product.found", true);
```

et dans `ReviewController.java` (le bagage) :

```java
Baggage baggage = Baggage.current().toBuilder()
        .put("app.review.channel", "web")
        .build();
try (Scope ignored = baggage.makeCurrent()) { ... }
```

Trois mécanismes du chapitre s'y trouvent — lesquels ?

{{%expand "Réponse" %}}
* **`@WithSpan`** (annotation) : crée un span `product-catalog.lookup`, enfant automatique du span serveur — équivalent déclaratif de `tracer.spanBuilder(...).startSpan()` ;
* **`@SpanAttribute` / `Span.current().setAttribute(...)`** : attributs posés sur le span courant ;
* **`Baggage`** : des paires clé/valeur qui **voyagent avec le contexte** (header W3C `baggage`) vers les services aval — contrairement aux attributs, qui restent sur leur span.

Lors du `POST /api/reviews`, le service appelle le **frontend** de la boutique (`GET /api/products/{id}`) : l'agent instrumente ce client HTTP et **propage le contexte** (header `traceparent`) — le frontend rejoint donc *votre* trace.
{{% /expand%}}

2.  **Générer une trace multi-services :**

```bash
kubectl port-forward -n otel-demo svc/review-service $APP_PORT:8080 &
curl -X POST http://localhost:$APP_PORT/api/reviews \
  -H "Content-Type: application/json" \
  -d '{"productId": "OLJCESPC7Z", "rating": 5, "comment": "Trace me!", "userEmail": "ada.lovelace@example.com", "userName": "Ada Lovelace"}'
```

3.  **Analyser la trace dans Jaeger** (service `review-service`, opération `POST /api/reviews`) :

{{%expand "Réponse" %}}
La hiérarchie attendue :

```text
POST /api/reviews                (review-service, span serveur)
├── product-catalog.lookup       (review-service, votre span manuel @WithSpan)
│   └── GET /api/products/{id}   (review-service, span client HTTP)
│       └── GET /api/products/…  (frontend ! propagation inter-services)
│           └── …                (spans internes du frontend)
├── INSERT reviews               (review-service, span JDBC)
```

Deux **services** dans une même trace = la propagation W3C Trace Context a fonctionné. Le bagage `app.review.channel=web` a voyagé dans les headers (il n'apparaît pas sur les spans : c'est un canal de transport, pas une donnée stockée — un processor peut le copier en attribut si besoin).
{{% /expand%}}

> 💡 Le span `INSERT reviews` est un span **client** (côté `review-service`) : vous ne trouverez **aucun span côté PostgreSQL**. La base n'est pas instrumentée et le protocole SQL ne transporte pas `traceparent` — la trace s'arrête à la base, qui est une **feuille**. La propagation ne marche qu'entre services instrumentés (ici `review-service` → `frontend`).

### Partie 2 — Tail sampling

4.  **Le problème :** en production, tracer 100 % du trafic coûte cher. Mais échantillonner **à la source** (head sampling) jette des traces avant de savoir si elles sont intéressantes. Le **tail sampling** décide *après coup*, dans le collecteur : on garde les erreurs et les requêtes lentes, on échantillonne le reste.

**Écrivez la politique** dans `manifests/70-otel-traces-values.yaml` : 100 % des traces en erreur, 100 % des traces > 1 s, 25 % du reste.

{{%expand "Réponse" %}}
Fichier de référence [`70-otel-traces-values.yaml`](../70-otel-traces-values.yaml). Pour l'utiliser tel quel :

```bash
cp content/1_Labs/70-otel-traces-values.yaml manifests/
```

Son contenu :

```yaml
opentelemetry-collector:
  config:
    processors:
      tail_sampling:
        decision_wait: 5s
        policies:
          - name: keep-errors
            type: status_code
            status_code:
              status_codes: [ERROR]
          - name: keep-slow
            type: latency
            latency:
              threshold_ms: 1000
          - name: sample-the-rest
            type: probabilistic
            probabilistic:
              sampling_percentage: 25
    service:
      pipelines:
        traces:
          processors: [memory_limiter, resourcedetection, resource, transform, tail_sampling, batch]
```

⚠️ Les politiques sont évaluées en **OU** : une trace est gardée si *au moins une* politique la retient. `decision_wait` : le collecteur retient les spans 5 s pour voir la trace entière avant de décider — c'est le coût mémoire du tail sampling. En multi-collecteurs, il faut router tous les spans d'une même trace vers la même instance (mode gateway + `loadbalancing` exporter).
{{% /expand%}}

5.  **Appliquer** (les values des labs précédents restent empilées) :

```bash
helm upgrade otel-demo open-telemetry/opentelemetry-demo \
  --version 0.40.9 -n otel-demo \
  -f manifests/values-training.yaml \
  -f manifests/30-otel-collector-values.yaml \
  -f manifests/60-otel-metrics-values.yaml \
  -f manifests/70-otel-traces-values.yaml
kubectl rollout status daemonset/otel-collector-agent -n otel-demo
```

6.  **Vérifier la politique :**

```bash
# ~20 requêtes OK (25 % devraient survivre) :
for i in $(seq 1 20); do curl -s http://localhost:$APP_PORT/api/reviews > /dev/null; done
# 3 erreurs (100 % doivent survivre) :
for i in $(seq 1 3); do
  curl -s -o /dev/null -X POST http://localhost:$APP_PORT/api/reviews \
    -H "Content-Type: application/json" \
    -d '{"productId": "DOESNOTEXIST", "rating": 5, "comment": "?", "userEmail": "x@example.com", "userName": "X"}'
done
```

Dans Jaeger : comptez les traces `GET /api/reviews` récentes (nettement moins de 20) et les traces en erreur (les 3, toutes marquées 🔴).

{{%expand "Pourquoi le load generator semble-t-il moins bavard ?" %}}
Le tail sampling s'applique à **tout** le pipeline traces : la démo entière est maintenant échantillonnée à 25 % (hors erreurs/lenteurs). Effet de bord assumé : les métriques **spanmetrics** (Lab 4) sont calculées *après* sampling dans notre pipeline — en production, on placerait le connector *avant* le tail sampling (deux pipelines chaînés) pour garder des métriques exactes.
{{% /expand%}}

## Livrable

Une trace multi-services (`review-service` + `frontend`) analysée, et la politique de tail sampling active (3/3 erreurs conservées, ~25 % du reste).
