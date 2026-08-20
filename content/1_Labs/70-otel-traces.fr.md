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
* Les accès ouverts (`./scripts/open-ui.sh`).
* Les variables de la formation chargées dans votre shell : `. ./scripts/env.sh`. Elles donnent le port du review-service (`$APP_PORT`, accès **direct** au service, pas via le frontend-proxy) et `$PF_HOST`, le nom par lequel vous le joignez.

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

> 💡 **Ce que fait l'agent, ce que vous faites.** L'agent Java n'est pas un bloc unique : c'est une collection d'une centaine de **modules d'instrumentation**, un par bibliothèque connue — Tomcat, JDBC, Hibernate, Spring Data, les clients HTTP… Au démarrage de la JVM, il **réécrit le bytecode** de ces bibliothèques pour ouvrir un span à l'entrée d'une méthode et le refermer à la sortie. Un span « automatique », c'est donc très concrètement **un appel à une méthode d'une bibliothèque reconnue** — et sa durée est celle de cet appel.
>
> Deux conséquences valent d'être retenues :
>
> * **Ce que l'agent ne reconnaît pas n'existe pas dans la trace.** Votre logique métier — la validation d'une note, un calcul de score — n'appartient à aucune bibliothèque connue : elle ne produit aucun span et apparaîtrait dans Jaeger comme un trou inexpliqué entre deux spans. C'est précisément ce manque que `@WithSpan` comble : l'agent couvre la plomberie, vous nommez ce qui a du sens pour votre métier.
> * **`@WithSpan` est lui aussi traité par l'agent.** L'annotation ne fait rien par elle-même : c'est un module de l'agent qui la reconnaît et crée le span. Retirez le `-javaagent` du Lab 2, et votre span manuel disparaît en même temps que les spans automatiques.
>
> Chaque span porte d'ailleurs la signature du module qui l'a produit, dans l'attribut **`otel.scope.name`** : `io.opentelemetry.tomcat-10.0` pour le span serveur, `io.opentelemetry.jdbc` pour l'`INSERT`, `io.opentelemetry.spring-data-1.8` pour `ReviewRepository.save`, et `…instrumentation-annotations-1.16` pour le vôtre. Dépliez n'importe quel span dans Jaeger pour le vérifier.
>
> Les identifiants, eux, ne se « déterminent » pas : à la création de chaque span, le SDK tire **8 octets au hasard** pour le `spanId` (16 au span racine pour le `traceId`). Aucune sémantique — toute l'information est dans le nom, les attributs, et le lien vers le span parent.

2.  **Générer une trace multi-services :**

```bash
. ./scripts/env.sh   # si ce n'est pas déjà fait dans ce terminal
curl -X POST http://$PF_HOST:$APP_PORT/api/reviews \
  -H "Content-Type: application/json" \
  -d '{"productId": "OLJCESPC7Z", "rating": 5, "comment": "Trace me!", "userEmail": "ada.lovelace@example.com", "userName": "Ada Lovelace"}'
```

3.  **Analyser la trace dans Jaeger** (service `review-service`, opération `POST /api/reviews`) :

{{%expand "Réponse" %}}
La colonne vertébrale de la trace :

```text
POST /api/reviews                          (review-service, span serveur)
├── product-catalog.lookup                 (review-service, votre span manuel @WithSpan)
│   └── GET                                (review-service, span client HTTP)
│       └── GET /api/products/{productId}  (frontend ! propagation inter-services)
│           └── …                          (spans du frontend, puis de product-catalog)
└── ReviewRepository.save                  (review-service, Spring Data)
    └── …                                  (spans Hibernate)
        └── INSERT otel                    (review-service, span JDBC)
```

**Votre trace en contient davantage** — une quinzaine de spans. Hibernate en intercale plusieurs entre `ReviewRepository.save` et l'`INSERT` (`Session.persist`, `Transaction.commit`), et le `frontend` poursuit en gRPC jusqu'à `product-catalog`, qui interroge à son tour sa base. L'arbre ci-dessus ne retient que le chemin principal ; les niveaux `…` sont là où le reste se déploie.

**Deux noms surprennent, et pourtant ils sont normaux.** Le span client s'appelle `GET` tout court : côté client, l'agent ne voit que l'URL concrète (`…/api/products/OLJCESPC7Z`), jamais sa forme paramétrée. La convention OpenTelemetry lui interdit alors de mettre l'URL dans le nom — sinon chaque produit créerait une opération différente et Jaeger deviendrait illisible. Quant à `INSERT otel`, le mot `otel` désigne la **base de données**, pas la table : la convention SQL est `{opération} {base}`.

**Trois services** dans une même trace (`review-service`, `frontend`, `product-catalog`) = la propagation W3C Trace Context a fonctionné. Le bagage `app.review.channel=web` a voyagé dans les headers (il n'apparaît pas sur les spans : c'est un canal de transport, pas une donnée stockée — un processor peut le copier en attribut si besoin).
{{% /expand%}}

> 💡 Le span `INSERT otel` est un span **client** (côté `review-service`) : vous ne trouverez **aucun span côté PostgreSQL**. La base n'est pas instrumentée et le protocole SQL ne transporte pas `traceparent` — la trace s'arrête à la base, qui est une **feuille**. La propagation ne marche qu'entre services instrumentés (ici `review-service` → `frontend` → `product-catalog`).

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

⚠️ Les politiques sont évaluées en **OU** : une trace est gardée si *au moins une* politique la retient. Conséquence à retenir : le trafic sans intérêt n'est pas **éliminé**, seulement **réduit**. Les sondes de santé de Kubernetes (`GET /actuator/health`, avec les requêtes SQL qu'elles déclenchent) ne sont ni en erreur ni lentes : elles tombent dans `sample-the-rest`, et **une sur quatre continue d'arriver dans Jaeger**. Pour les écarter vraiment, il faut les jeter *avant* l'échantillonnage — un `filter` processor sur `http.route`, ou une politique `string_attribute` dédiée. `decision_wait` : le collecteur retient les spans 5 s pour voir la trace entière avant de décider — c'est le coût mémoire du tail sampling. En multi-collecteurs, il faut router tous les spans d'une même trace vers la même instance (mode gateway + `loadbalancing` exporter).
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
for i in $(seq 1 20); do curl -s http://$PF_HOST:$APP_PORT/api/reviews > /dev/null; done
# 3 erreurs (100 % doivent survivre) :
for i in $(seq 1 3); do
  curl -s -o /dev/null -X POST http://$PF_HOST:$APP_PORT/api/reviews \
    -H "Content-Type: application/json" \
    -d '{"productId": "DOESNOTEXIST", "rating": 5, "comment": "?", "userEmail": "x@example.com", "userName": "X"}'
done
```

Dans Jaeger : comptez les traces `GET /api/reviews` récentes (nettement moins de 20) et les traces en erreur (les 3, toutes marquées 🔴).

{{%expand "Pourquoi le load generator semble-t-il moins bavard ?" %}}
Le tail sampling s'applique à **tout** le pipeline traces : la démo entière est maintenant échantillonnée à 25 % (hors erreurs/lenteurs). Effet de bord assumé : les métriques **spanmetrics** (Lab 4) sont calculées *après* sampling dans notre pipeline — en production, on placerait le connector *avant* le tail sampling (deux pipelines chaînés) pour garder des métriques exactes.
{{% /expand%}}

## Livrable

Une trace multi-services (`review-service` → `frontend` → `product-catalog`) analysée, et la politique de tail sampling active (3/3 erreurs conservées, ~25 % du reste).
