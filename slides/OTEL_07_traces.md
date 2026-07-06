---
marp: true
theme: custom-theme
paginate: true
backgroundColor: #ffffff
---

# Formation OpenTelemetry

## Chapitre 7 — Traces

<img src="images/logo.svg" alt="K8s School Logo" width="50%">

---

## Le modèle de données

- **Span** : une opération (nom, début, durée, statut) +
  - **attributs** : `http.route`, `db.system`, `app.product.id`...
  - **events** : points datés dans le span (exception, retry...)
  - **links** : relations entre traces (batch, fan-out)
- **Trace** = l'arbre des spans reliés par `trace_id` + parenté
- `SpanKind` : SERVER, CLIENT, INTERNAL, PRODUCER, CONSUMER

---

## SDK Tracer

- `TracerProvider` → `Tracer` → spans manuels :

```java
Span span = tracer.spanBuilder("product-catalog.lookup").startSpan();
try (Scope scope = span.makeCurrent()) {
    ...
    span.setAttribute("app.product.found", true);
} finally {
    span.end();
}
```

- Le span courant est accessible partout : `Span.current()`
- L'instrumentation auto (agent) et manuelle **s'imbriquent** naturellement

---

## Annotations

- Le span manuel sans le code de plomberie :

```java
@WithSpan("product-catalog.lookup")
public void checkProductExists(@SpanAttribute("app.product.id") String productId)
```

- `io.opentelemetry.instrumentation:opentelemetry-instrumentation-annotations`
- Interprétées par l'agent **et** par le starter
- Sans SDK actif : no-op — zéro risque à instrumenter

---

## Contexte de trace & bagage

- **Contexte** : `trace_id` + `span_id` courant, propagé
  - en HTTP : header **W3C `traceparent`** — injecté/extrait automatiquement
  - c'est lui qui fait qu'un appel `review-service` → `frontend` = **une seule trace**
- **Baggage** : des clés/valeurs métier qui **voyagent avec** le contexte

```java
Baggage.current().toBuilder().put("app.review.channel", "web").build().makeCurrent();
```

- ⚠️ Le bagage transite en clair dans les headers : jamais de secret ;
  il n'est **pas** stocké sur les spans (un processor peut l'y copier)

---

## Échantillonnage : head vs tail

- Tracer 100 % en prod = coût stockage/réseau élevé
- **Head sampling** (dans le SDK) : décision **à la création** de la trace
  - simple, pas cher... mais aveugle : jette aussi les erreurs
  - `OTEL_TRACES_SAMPLER=parentbased_traceidratio`
- **Tail sampling** (dans le collecteur) : décision **une fois la trace complète**
  - garder 100 % des erreurs et des requêtes lentes, échantillonner le reste
  - coût : mémoire (retenir les spans) + tous les spans d'une trace
    doivent atteindre **la même instance** de collecteur
- **Rate limiting** : borne dure en volume (policy `rate_limiting`)

---

## Processor tail_sampling

```yaml
tail_sampling:
  decision_wait: 5s
  policies:
    - name: keep-errors
      type: status_code
      status_code: {status_codes: [ERROR]}
    - name: keep-slow
      type: latency
      latency: {threshold_ms: 1000}
    - name: sample-the-rest
      type: probabilistic
      probabilistic: {sampling_percentage: 25}
```

- Politiques évaluées en **OU**
- En multi-collecteurs : exporter `loadbalancing` (routage par trace_id) en amont

---

## 🧪 LAB 7 — Traces manuelles & échantillonnage

- Lire `@WithSpan`, attributs et **baggage** dans le code
- Générer une trace **multi-services** (`review-service` → `frontend`)
- Mettre en place le **tail sampling** : 100 % des erreurs, 25 % du reste
- Vérifier : les erreurs survivent, le bruit diminue

➡ [Lab 7 — Traces & échantillonnage](https://k8s-school.fr/otel/fr/1_labs/70-otel-traces/index.html)
