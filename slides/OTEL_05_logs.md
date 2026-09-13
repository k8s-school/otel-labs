---
marp: true
theme: custom-theme
paginate: true
backgroundColor: #ffffff
---

<!-- _class: title -->

# Formation OpenTelemetry

## Chapitre 5 — Logs

![K8s School w:400](images/logo.svg)&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;![Sparks w:300](images/sparks-logo.png)

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

## Logs structurés : ce qu'on gagne, ce qu'on paie

| Ce qu'on gagne | Ce qu'on paie |
|---|---|
| Un log texte se **grep**, un log structuré se **requête** | Le JSON pèse plus lourd que la ligne de texte |
| Le `trace_id` est attaché : la corrélation devient gratuite | Illisible à l'œil nu — `kubectl logs` renvoie du JSON |
| Plus de regex de parsing à maintenir à l'ingestion | Il faut nommer les champs, et s'y tenir en équipe |

- Règle d'or : des **paires clé/valeur**, pas des phrases à parser
- Enrichissement contextuel : **MDC** Logback → attributs OTel
- Exemple côté Java : le [`JsonEncoder` de Logback](https://logback.qos.ch/manual/encoders.html#JsonEncoder) — une ligne JSON par événement, MDC inclus
- En pratique on garde les deux : la sortie console du conteneur reste lisible, le structuré part en OTLP

---

## L'appender Logback OpenTelemetry

- OpenTelemetry fournit une bibliothèque, `opentelemetry-logback-appender` :
  un appender Logback qui transforme chaque événement en **LogRecord OTLP**
- **Rien à configurer**, ni avec l'agent ni avec le starter : chacun branche
  cet appender automatiquement au démarrage — `review-service` n'a pas de `logback.xml`
- Le `trace_id` courant est attaché **automatiquement** : la corrélation est gratuite
- Le déclarer soi-même dans `logback.xml` ne sert qu'à régler ce qu'il capture
  (MDC, marqueurs…) ou quand on instrumente à la main, sans agent ni starter

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
  - OpenSearch **ne parle pas OTLP** : l'exporter traduit chaque LogRecord en JSON
    et le pousse par l'API `_bulk` d'OpenSearch (HTTP, port 9200)

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
