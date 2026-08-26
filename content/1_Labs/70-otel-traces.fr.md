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

**Deux noms surprennent, et pourtant ils sont normaux.**

**`GET` tout court.** Repérez dans votre trace les deux extrémités du *même* appel HTTP :

```text
GET                                (review-service — celui qui appelle)
└── GET /api/products/{productId}  (frontend — celui qui répond)
```

Le service qui **répond** sait quelle route a été empruntée : c'est lui qui a comparé l'URL reçue à la liste de ses routes déclarées, et il connaît donc le **gabarit** `/api/products/{productId}`. Il le met dans le nom du span.

Le service qui **appelle** n'a jamais eu ce gabarit entre les mains. Son agent voit passer une chaîne de caractères, `http://frontend:8080/api/products/OLJCESPC7Z`, et rien ne lui dit lequel de ces morceaux est une variable : `OLJCESPC7Z` pourrait tout aussi bien être un segment fixe du chemin.

Reste la question : pourquoi ne pas nommer le span avec l'URL complète, à défaut de mieux ? Parce que le nom d'un span doit avoir **peu de valeurs distinctes** — c'est ce qui permet à Jaeger de proposer une liste d'opérations, et à `spanmetrics` (Lab 4) d'agréger les latences par opération. Avec l'URL, le catalogue de 10 produits de la démo créerait 10 opérations ; un vrai catalogue de 50 000 références en créerait 50 000. L'agent s'abstient donc, et ne garde que la méthode HTTP. L'URL complète, elle, n'est pas perdue : elle est dans l'attribut `url.full` du span.

**`INSERT otel`.** Le mot `otel` désigne la **base de données**, pas la table : la convention SQL est `{opération} {base}`.

**Trois services** dans une même trace (`review-service`, `frontend`, `product-catalog`) = la propagation **W3C Trace Context** a fonctionné.

Ce n'est pas un mécanisme OpenTelemetry, mais une **spécification du W3C** — [Trace Context](https://www.w3.org/TR/trace-context/) — c'est-à-dire un standard du Web au même titre que HTTP. Elle définit un en-tête que tout outil sait lire, quels que soient le langage et le fournisseur :

```text
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             │  │                                │                └─ flags (01 = trace échantillonnée)
             │  │                                └─ span-id de l'appelant, qui devient le parent
             │  └─ trace-id : le même pour les trois services
             └─ version du format
```

Avant ce standard, chaque outil avait le sien (`b3` chez Zipkin, `uber-trace-id` chez Jaeger) : deux services instrumentés avec des produits différents ne pouvaient pas partager une trace.

Quant au bagage `app.review.channel=web`, il a lui aussi voyagé dans les headers (il n'apparaît pas sur les spans : c'est un canal de transport, pas une donnée stockée — un processor peut le copier en attribut si besoin).
{{% /expand%}}

> 💡 Le span `INSERT otel` est un span **client** (côté `review-service`) : vous ne trouverez **aucun span côté PostgreSQL**. La base n'est pas instrumentée et le protocole SQL ne transporte pas `traceparent` — la trace s'arrête à la base, qui est une **feuille**. La propagation ne marche qu'entre services instrumentés (ici `review-service` → `frontend` → `product-catalog`).

4.  **Prouver la propagation.** Jusqu'ici le contexte naissait dans `review-service` : votre `curl` arrivait sans en-tête, l'agent n'avait donc rien à reprendre. Imposez-le vous-même, comme le ferait un service appelant :

```bash
. ./scripts/env.sh   # si ce n'est pas déjà fait dans ce terminal
curl -s -o /dev/null -X POST http://$PF_HOST:$APP_PORT/api/reviews \
  -H "Content-Type: application/json" \
  -H "traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" \
  -d '{"productId": "OLJCESPC7Z", "rating": 5, "comment": "w3c", "userEmail": "a@b.c", "userName": "A"}'
```

Cherchez `4bf92f3577b34da6a3ce929d0e0e4736` dans le champ **Trace ID** de Jaeger, en haut à droite du bandeau. Que trouvez-vous — et qu'est-ce que cela prouve ?

{{%expand "Réponse" %}}
La trace est là, sous **l'identifiant que vous avez choisi**, et elle traverse les trois services. L'agent n'a donc pas généré de `trace-id` : trouvant un `traceparent` valide à l'entrée de la requête, il l'a repris tel quel, puis l'a propagé au `frontend`, qui l'a propagé à `product-catalog`.

Regardez le span `POST /api/reviews` : son parent est `00f067aa0ba902b7`, le `span-id` que vous avez inventé. Il ne correspond à aucun span de Jaeger, et personne ne s'en émeut — **rien, dans le protocole, ne permet de vérifier qu'un parent annoncé existe**. C'est précisément ce qui rend la propagation possible entre des services qui ne se connaissent pas : chacun fait confiance à l'en-tête reçu.

C'est aussi ce qui se passe, en temps normal, à chaque saut : le `traceparent` que `review-service` envoie au `frontend` désigne comme parent le span client `GET` que vous avez lu à l'étape 3. Vous venez simplement de jouer le rôle du service appelant.

⚠️ Le revers, pour le Lab 8 : un client peut **injecter** le `traceparent` de son choix, donc écrire dans vos traces. Sur un endpoint exposé au public, le contexte entrant se filtre ou se re-crée.
{{% /expand%}}

### Partie 2 — Tail sampling

5.  **Le problème :** en production, tracer 100 % du trafic coûte cher. Mais échantillonner **à la source** (head sampling) jette des traces avant de savoir si elles sont intéressantes. Le **tail sampling** décide *après coup*, dans le collecteur : on garde les erreurs et les requêtes lentes, on échantillonne le reste.

**Écrivez la politique** dans `manifests/70-otel-traces-values.yaml` : 100 % des traces en erreur, 100 % des traces > 1 s, 25 % du reste.

Trois politiques à combiner, une par ligne de l'énoncé.

Pour démarrer, le [billet officiel sur le tail sampling](https://opentelemetry.io/blog/2022/tail-sampling/#how-to-implement-tail-sampling-in-the-opentelemetry-collector) donne un exemple court : deux politiques, dont **deux des trois** qui vous sont demandées. La [documentation du processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/tailsamplingprocessor/README.md) liste ensuite tous les types et leurs paramètres — c'est là que vous trouverez la troisième, `latency`. Et le concept lui-même, head *vs* tail, est résumé dans la [doc OpenTelemetry sur l'échantillonnage](https://opentelemetry.io/docs/concepts/sampling/).

> ⚠️ Les exemples officiels écrivent les politiques **en ligne**, avec des accolades (`{name: …, type: …}`), et le README enchaîne 23 politiques nommées `test-policy-1`, `test-policy-2`… ne cherchez pas de sens à ces noms, c'est un fichier de test. Le YAML du lab utilise l'indentation classique : les deux écritures sont strictement équivalentes, choisissez celle que vous lisez le mieux.

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
        # Une trace arrive en morceaux, souvent depuis plusieurs services. Le
        # collecteur les met de côté pendant ce délai avant de trancher : trop
        # court, il décide sur une trace incomplète et rate l'erreur qui arrive
        # en retard ; trop long, tout ce qui patiente occupe la mémoire.
        # Défaut du processor : 30 s.
        decision_wait: 5s
        policies:
          # Les politiques sont évaluées en OU : la trace est gardée dès que
          # l'une d'elles la retient.
          - name: keep-errors
            type: status_code
            status_code:
              status_codes: [ERROR]
          - name: keep-slow
            # Durée de la trace entière (du premier au dernier span), et non
            # celle d'un span pris isolément.
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
          # tail_sampling doit précéder batch : il raisonne trace par trace,
          # quand batch ne fait que regrouper des spans pour les expédier.
          processors: [memory_limiter, resourcedetection, resource, transform, tail_sampling, batch]
```

⚠️ Les politiques sont évaluées en **OU** : une trace est gardée si *au moins une* politique la retient. Conséquence à retenir : le trafic sans intérêt n'est pas **éliminé**, seulement **réduit**. Les sondes de santé de Kubernetes (`GET /actuator/health`, avec les requêtes SQL qu'elles déclenchent) ne sont ni en erreur ni lentes : elles tombent dans `sample-the-rest`, et **une sur quatre continue d'arriver dans Jaeger**. Pour les écarter vraiment, il faut les jeter *avant* l'échantillonnage — un `filter` processor sur `http.route`, ou une politique `string_attribute` dédiée.
{{% /expand%}}

> 💡 **Pourquoi votre tail sampling fonctionne — et pourquoi il casserait en production.**
>
> Le collecteur de la démo est un **DaemonSet** : une instance par nœud. Votre cluster kind n'en a qu'un, donc l'unique collecteur voit **tous** les spans de chaque trace. C'est la condition sans laquelle rien de ce que vous venez d'écrire ne tient : pour décider si une trace est en erreur ou lente, il faut la posséder en entier.
>
> Ajoutez un second nœud, et les spans d'une même trace se répartissent entre deux collecteurs qui ne se parlent pas. Chacun tranche sur la moitié qu'il voit : celui qui n'a pas reçu le span en erreur traite la trace comme ordinaire et l'échantillonne à 25 %. Vous récoltez alors des **traces amputées** — plus trompeuses qu'une trace absente, puisqu'elles ont l'air complètes.
>
> La parade tient en deux étages. Les collecteurs de nœud n'échantillonnent plus : ils transmettent à un étage **gateway** ([mode gateway](https://opentelemetry.io/docs/collector/deployment/gateway/), un Deployment de quelques instances), dont l'exporter [`loadbalancing`](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/exporter/loadbalancingexporter/README.md) route **par `traceId`**. Tous les spans d'une même trace atterrissent ainsi sur la même instance de gateway — la seule à porter le `tail_sampling`.
>
> Ce n'est pas une bizarrerie du tail sampling, mais un cas particulier d'un principe que la [documentation officielle sur la montée en charge](https://opentelemetry.io/docs/collector/scaling/) énonce ainsi : *« les composants comme le tail sampling processor ne se répartissent pas facilement, car ils conservent en mémoire l'état nécessaire à leur fonctionnement »*. Tout processor à état pose la même question : qui voit quoi, et est-ce suffisant pour décider ?

6.  **Appliquer** (les values des labs précédents restent empilées) :

```bash
helm upgrade otel-demo open-telemetry/opentelemetry-demo \
  --version 0.40.9 -n otel-demo \
  -f manifests/values-training.yaml \
  -f manifests/30-otel-collector-values.yaml \
  -f manifests/60-otel-metrics-values.yaml \
  -f manifests/70-otel-traces-values.yaml
kubectl rollout status daemonset/otel-collector-agent -n otel-demo
```

7.  **Vérifier la politique :**

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

Dans Jaeger, faites **deux recherches distinctes** — ce ne sont pas les mêmes opérations :

* *Operation* `GET /api/reviews` : comptez les traces récentes. Vous en avez envoyé 20, il doit en rester nettement moins — c'est `sample-the-rest` à l'œuvre, et le compte exact varie d'un tirage à l'autre.
* *Operation* `POST /api/reviews`, avec *Tags* `error=true` : les **3** doivent être là, toutes marquées 🔴. `keep-errors` ne laisse rien passer, quel que soit le pourcentage de la politique probabiliste.

C'est le contraste entre ces deux comptes qui prouve que la politique fonctionne : le trafic ordinaire est réduit, les erreurs sont intégralement conservées.

**Et si compter à la main vous laisse dubitatif**, le processor tient ses propres comptes, que le collecteur exporte comme n'importe quelle métrique. Commencez par la **décision finale** :

```promql
sum by (sampled) (otelcol_processor_tail_sampling_global_count_traces_sampled_total)
```

```text
sampled="true"    581     ← traces conservées
sampled="false"  1349
```

Puis le détail, **politique par politique** :

```promql
sum by (policy, sampled) (otelcol_processor_tail_sampling_count_traces_sampled_total)
```

```text
policy="keep-errors"       sampled="true"      8    sampled="false"  1922
policy="keep-slow"         sampled="true"    153    sampled="false"  1777
policy="sample-the-rest"   sampled="true"    468    sampled="false"  1462
```

⚠️ **Ce second compteur se lit de travers si l'on n'y prend pas garde.** Il enregistre **un vote par politique et par trace** : `keep-errors / sampled="false" = 1922` ne signifie pas que 1922 traces en erreur ont été jetées, mais que 1922 fois, `keep-errors` a examiné une trace et n'y a trouvé aucune erreur à retenir. Vos erreurs, ce sont les **8** votes `true` — et elles sont toutes conservées.

La preuve tient dans les totaux : `8 + 1922`, `153 + 1777`, `468 + 1462` donnent tous **1930**, le nombre de traces évaluées. Chaque politique voit chaque trace, et se prononce.

Deux lectures valent le détour :

* `468 / (468 + 1462) = 24,2 %` — la politique probabiliste tient sa promesse, chiffre à l'appui, sans que vous ayez à compter des lignes à l'écran ;
* `8 + 153 + 468 = 629`, alors que la décision finale n'en retient que **581**. L'écart, ce sont les traces retenues par **plusieurs** politiques à la fois — une trace lente que le tirage aurait de toute façon gardée. Le **OU** ne les compte qu'une fois.

{{%expand "Pourquoi le load generator semble-t-il moins bavard ?" %}}
Le tail sampling s'applique à **tout** le pipeline traces : la démo entière est maintenant échantillonnée à 25 % (hors erreurs/lenteurs).

Effet de bord assumé, et mesurable : les métriques **spanmetrics** (Lab 4) sont calculées *après* le sampling dans notre pipeline, donc elles ne comptent plus que les spans survivants. Vérifiez-le sur le débit global :

```promql
sum(rate(traces_span_metrics_calls_total[5m]))
```

Ouvrez-la dans l'onglet **Graph** de Prometheus, sur la dernière heure : vous n'avez pas besoin de comparer deux chiffres, la marche d'escalier se voit à l'œil nu, à l'instant précis du `helm upgrade`.

```text
11:25   17.8  #################
11:30   17.3  #################
11:35   15.2  ###############
11:40    5.7  #####            ← le tail sampling entre en action
11:45    7.1  #######
```

Relevé sur le cluster de la formation : **~17 spans/s → ~6 spans/s**, soit l'ordre de grandeur des 25 % conservés. Les panels de latence et de débit du Lab 4 sont donc alimentés par un quart du trafic — ils restent lisibles, mais ne comptent plus tout.

En production, on placerait donc le connector `spanmetrics` **avant** le tail sampling (deux pipelines chaînés) : les métriques restent exactes, seul le stockage des traces est réduit.
{{% /expand%}}

## Livrable

Une trace multi-services (`review-service` → `frontend` → `product-catalog`) analysée, et la politique de tail sampling active (3/3 erreurs conservées, ~25 % du reste).
