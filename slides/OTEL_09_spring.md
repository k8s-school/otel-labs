---
marp: true
theme: custom-theme
paginate: true
backgroundColor: #ffffff
---

# Formation OpenTelemetry

## Chapitre 9 — Framework Spring *(facultatif)*

<img src="images/logo.svg" alt="K8s School Logo" width="50%">

---

## Deux mondes qui convergent

- L'écosystème Spring a **son propre** stack d'observabilité :
  - **Micrometer** (métriques) — vu au chapitre 6
  - **Micrometer Tracing** (successeur de Spring Cloud Sleuth)
- OpenTelemetry arrive avec agent, starter, SDK...
- Question fréquente en entreprise : **lequel choisir ?**

---

## Appender Logback dans Spring

- Spring Boot configure Logback via `logback-spring.xml`
- L'appender OTel s'y déclare comme n'importe quel appender :

```xml
<appender name="OTel" class="io.opentelemetry.instrumentation.logback
                             .appender.v1_0.OpenTelemetryAppender"/>
<root level="INFO">
  <appender-ref ref="CONSOLE"/>
  <appender-ref ref="OTel"/>
</root>
```

- Rappel : avec l'**agent** ou le **starter**, injection automatique — rien à écrire

---

## Micrometer & OTLP

- Micrometer sait exporter en OTLP **sans OpenTelemetry** :
  `micrometer-registry-otlp` + `management.otlp.metrics.export.url=...`
- Trois chemins vers le même collecteur :

| Chemin | Dépendance | Config |
|--------|------------|--------|
| Agent OTel (bridge) | aucune | `OTEL_*` |
| Starter OTel | starter | `OTEL_*` |
| Micrometer natif | registry-otlp | `management.otlp.*` |

---

## Micrometer Tracing & OTLP

- `micrometer-tracing-bridge-otel` : l'API Micrometer (Observation),
  le moteur OpenTelemetry en dessous
- `Observation` = **un concept, trois signaux** : timer + span + logs corrélés

```java
Observation.createNotStarted("review.create", registry)
    .observe(() -> ...);
```

- Micrometer vs OTel pur : lecture recommandée —
  [Distributed tracing with Spring Boot 3 — Micrometer vs OpenTelemetry](https://itnext.io/distributed-tracing-with-spring-boot-3-micrometer-vs-opentelemetry-b3593546f61b)

---

## Quelle stratégie retenir ?

- Équipes **Spring-first** : API Micrometer/Observation dans le code,
  export OTLP → la plateforme reste 100 % OpenTelemetry
- Équipes **polyglottes** (notre cas Astronomy Shop) : API OpenTelemetry
  partout, agent en zero-code — cohérence inter-langages
- Dans tous les cas : **OTLP vers un collecteur**, conventions sémantiques —
  le backend ne voit pas la différence
