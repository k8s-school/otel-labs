---
marp: true
theme: custom-theme
paginate: true
backgroundColor: #ffffff
---

# Formation OpenTelemetry

## Chapitre 6 — Métriques

<img src="images/logo.svg" alt="K8s School Logo" width="50%">

---

## Le modèle de données

- Une **métrique** = nom + unité + type + points de données horodatés
- Chaque point porte des **attributs** (dimensions) : `{method="POST", status="201"}`
- **Temporalité** : cumulative (Prometheus) ou delta
- ⚠️ **Cardinalité** : chaque combinaison d'attributs = une série
  - `user_id` dans une métrique = explosion mémoire garantie
  - les identifiants vont dans les **traces**, pas dans les métriques

---

## Les types d'instruments

| Type | Usage | Exemple |
|------|-------|---------|
| **Counter** | cumul monotone | `reviews.created` |
| **UpDownCounter** | cumul ± | connexions actives |
| **Gauge** | valeur instantanée | température, taille de file |
| **Histogram** | distribution | latence (p50/p95/p99) |

- L'histogramme est le grand gagnant pour les latences :
  buckets → percentiles calculables a posteriori

---

## Java : l'API OpenTelemetry

- Même chaîne de types dans tous les langages :
  **`MeterProvider` → `Meter` → instrument**

```java
Meter meter = GlobalOpenTelemetry.getMeter("fr.k8sschool.reviews");
LongCounter created = meter.counterBuilder("reviews.created").build();
DoubleHistogram duration = meter
     .histogramBuilder("reviews.creation.duration").setUnit("ms").build();
created.add(1, Attributes.of(RATING, 5L));   // attribut = dimension
```

- **API ≠ SDK** : sans SDK dans la JVM, l'API est **no-op** — le code compile,
  tourne, et ne produit rien. L'agent du Lab 2 installe le SDK.
- Le nom passé à `getMeter()` = **scope d'instrumentation** (`otel.scope.name`)

---

## Java : et Micrometer ?

- La façade métriques **standard de Spring** (fournie par Actuator) :
  toute application Spring en a déjà

```java
Timer.builder("reviews.creation.time")
     .publishPercentileHistogram()
     .register(registry);
```

- L'agent OTel fait le **pont** : meter Micrometer → métrique OTLP
- ⚠️ Pont **opt-in** : `OTEL_INSTRUMENTATION_MICROMETER_ENABLED=true`
- Annotations : `@Timed`, `@Counted` (Micrometer) — même résultat en déclaratif
- Code neuf → **API OTel** (seul chemin pour les traces et les logs) ;
  patrimoine Micrometer → **le pont**, pas une réécriture

---

## Rappels Prometheus

- Le standard de facto des métriques : base de séries temporelles + PromQL
- Modèle **pull** historique (scrape `/metrics`)... 
- ...mais Prometheus parle désormais **OTLP natif** (push) — c'est le mode de la démo :

```yaml
exporters:
  otlphttp/prometheus:
    endpoint: http://prometheus:9090/api/v1/otlp
```

- Traduction des noms : `reviews.created` → `reviews_created_total`

---

## Côté collecteur

- Receiver **`prometheus`** : scraper des `/metrics` existants (compatibilité)
- Exporter **`prometheus`** : exposer un `/metrics` à scraper
- Receivers « produit » : `postgresql`, `kafkametrics`, `hostmetrics` (Lab 3)
- **Connectors** traces → métriques :
  - **`spanmetrics`** : débit + latence par opération (déjà actif dans la démo)
  - **`count`** : compter des événements (ex : spans en erreur)
- Des métriques **sans instrumenter** : dérivées des traces

---

## 🧪 LAB 6 — Métriques métier

- **Partie 1** : compteur + histogramme avec l'**API OpenTelemetry** dans
  `review-service`, export via l'agent, latence p95 en PromQL
- **Partie 2** : le **pont Micrometer** — un flag, et le patrimoine Spring suit
- **Partie 3** : connector **`count`** — compter les spans en erreur,
  `app_spans_errors_total` sans une ligne de code

➡ [Lab 6 — Métriques métier](https://k8s-school.fr/labs/otel/fr/1_labs/60-otel-metrics/index.html)

*Livrable : graphe de latence + compteur métier + métrique dérivée.*
