---
marp: true
theme: custom-theme
paginate: true
backgroundColor: #ffffff
---

# Formation OpenTelemetry

## Chapitre 5 — Logs

<img src="images/logo.svg" alt="K8s School Logo" width="50%">

---

## Le modèle de données : LogRecord

- OTel ne réinvente pas le logging : il **structure et transporte** l'existant
- Un **LogRecord** :

| Champ | Exemple |
|-------|---------|
| `timestamp` | 2026-07-06T10:42:01Z |
| `severity` | INFO (texte + numéro 1-24) |
| `body` | `Creating review for product X` |
| `attributes` | `code.namespace=ReviewController` |
| `resource` | `service.name=review-service` |
| **`trace_id` / `span_id`** | la corrélation log ↔ trace |

---

## SDK LoggerProvider

- Le pendant « logs » du TracerProvider / MeterProvider
- Pipeline SDK : `LoggerProvider` → **LogRecordProcessor** (batch, enrichissement,
  masquage d'attributs) → **LogRecordExporter** (OTLP)
- En pratique en Java, on ne l'appelle presque jamais directement :
  un **appender** fait le pont depuis Logback

---

## Logs structurés

- Un log texte libre se **grep** ; un log structuré se **requête**
- Structuré = champs séparés : severity, attributs, resource... (le LogRecord !)
- Enrichissement contextuel : **MDC** Logback → attributs OTel
- Règle d'or : des **paires clé/valeur**, pas des phrases à parser

---

## L'appender Logback OpenTelemetry

- `opentelemetry-logback-appender` : chaque événement Logback → LogRecord OTLP

```xml
<appender name="OTel"
  class="io.opentelemetry.instrumentation.logback.appender.v1_0.OpenTelemetryAppender">
</appender>
```

- **Avec l'agent Java : rien à faire** — il injecte l'équivalent automatiquement
- Le `trace_id` courant est attaché **automatiquement** : la corrélation est gratuite

---

## Côté collecteur

- Receiver **`otlp`** : les logs poussés par les SDKs/agents (notre cas)
- Receiver **`filelog`** : lire des fichiers (applis legacy, logs de pods)

```yaml
filelog:
  include: [/var/log/pods/*/*/*.log]
  operators:
    - type: container   # parse le format kubelet
```

- Receiver **`syslog`** : équipements, systèmes
- Processor **transform (OTTL)** : parser, normaliser la sévérité, **masquer** (Lab 8)
- Pipeline de la démo : `otlp → [processors] → opensearch`

---

## 🧪 LAB 5 — Logs structurées et corrélées

- Comparer `kubectl logs` (texte brut) et OpenSearch (LogRecords structurés)
- Suivre le trajet : Logback → agent → OTLP → collecteur → OpenSearch
- Naviguer **du log à la trace** en un clic dans Grafana
- Repérer une **PII dans un log**... (à suivre au Lab 8)

➡ [Lab 5 — Logs structurées](https://k8s-school.fr/labs/otel/fr/1_labs/50-otel-logs/index.html)

---

## Annexe — Java : SLF4J & Logback — rappels

- **SLF4J** : la façade (l'API que voit le code)
- **Logback** : l'implémentation (appenders, encoders, niveaux)

```java
private static final Logger logger = LoggerFactory.getLogger(ReviewController.class);
logger.info("Creating review for product {}", productId);
```

- Le code applicatif **ne change pas** avec OpenTelemetry : on branche la sortie
