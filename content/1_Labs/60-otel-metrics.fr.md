---
title: 'Lab 6 — Métriques métier'
date: 2026-07-06T11:40:00+02:00
draft: false
weight: 60
tags: ["OpenTelemetry", "métriques", "SDK", "Micrometer", "Prometheus"]
---

Le Lab 3 collectait des métriques d'**infrastructure** (système, PostgreSQL) ; le connector spanmetrics fournit déjà débit et latence par service. Il manque les métriques **métier** : combien d'avis créés ? En combien de temps ? Dans ce lab, vous écrivez ces métriques vous-même avec l'**API OpenTelemetry** (un compteur + un histogramme), vous découvrez ensuite le **pont Micrometer** pour les applications Spring qui ont déjà leur instrumentation, puis vous dérivez une métrique depuis les spans avec le connector **`count`**.

## Prérequis

* Labs 1 à 3 terminés, agent Java actif sur `review-service` (cf. [Lab 5, étape 2]({{% relref "50-otel-logs.fr.md" %}}) — l'étape 2 ci-dessous le vérifie).
* **D'abord** les variables de la formation chargées dans votre shell : `. ./scripts/env.sh`. Elles donnent le port du review-service (`$APP_PORT`, accès **direct** au service, pas via le frontend-proxy) et `$PF_HOST`, le nom par lequel vous le joignez.
* Les accès ouverts (`./scripts/open-ui.sh`) : Prometheus est sur `http://$PF_HOST:$PROM_PORT/`.

## Étapes

### Partie 1 — Un compteur et un histogramme avec l'API OpenTelemetry

1.  **Lire l'instrumentation** dans `apps/review-service/src/main/java/fr/k8sschool/reviews/ReviewController.java`. Les deux instruments sont créés une fois, dans le constructeur :

```java
Meter meter = GlobalOpenTelemetry.getMeter("fr.k8sschool.reviews");
this.reviewsCreated = meter.counterBuilder("reviews.created")
        .setDescription("Number of product reviews created")
        .setUnit("{review}")
        .build();
this.reviewCreationDuration = meter.histogramBuilder("reviews.creation.duration")
        .setDescription("Time spent creating a review (catalog check + insert)")
        .setUnit("ms")
        .build();
```

et alimentés à chaque création d'avis :

```java
Attributes attributes = Attributes.of(RATING, (long) review.getRating());
reviewsCreated.add(1, attributes);
reviewCreationDuration.record((System.nanoTime() - startNanos) / 1_000_000.0, attributes);
```

{{%expand "Au fait, qu'est-ce qu'`Attributes` ?" %}}
Un sac de paires **clé → valeur** attaché à *chaque mesure*. C'est lui qui permettra, à l'étape 4, de découper la métrique — « combien d'avis, et pour quelle note ? ».

**La clé est typée**, et se déclare une fois pour toutes :

```java
private static final AttributeKey<Long>   RATING  = AttributeKey.longKey("app.review.rating");
private static final AttributeKey<String> PRODUCT = AttributeKey.stringKey("app.product.id");
```

Le type vit dans la clé, pas dans la valeur : le compilateur refuse `Attributes.of(RATING, "cinq")`. OpenTelemetry n'accepte que quatre types — `String`, `Long`, `Double`, `Boolean` — et leurs tableaux (`stringArrayKey`, `longArrayKey`…). Pas d'`int`, d'où le `(long)` dans le code du contrôleur.

Pourquoi `static final` ? D'abord parce qu'une clé d'attribut est une **constante de l'application**, au même titre que le nom de la métrique : déclarée en haut de la classe, elle s'écrit une fois et se relit partout. Recopiez la chaîne à la main dans deux appels, glissez un `app.review.Rating` dans l'un des deux, et vous obtenez **deux séries distinctes** — sans une erreur du compilateur ni le moindre message à l'exécution. Accessoirement, une `AttributeKey` porte un hash et un encodage UTF-8 précalculés, que le SDK réutilise à chaque mesure et à chaque export : la reconstruire à chaque avis créé, c'est refaire ce travail pour rien.

**Plusieurs paires ?** `Attributes.of` en accepte de une à six. Au-delà, ou quand une paire est conditionnelle, on passe par le builder :

```java
Attributes.builder()
        .put(RATING, 5L)
        .put(PRODUCT, "OLJCESPC7Z")
        .build();
```

L'objet obtenu est **immuable et trié** : l'ordre d'écriture n'a aucune importance, `{rating, product}` et `{product, rating}` désignent la même série.

**Et la taille ?** Rien dans l'API ne vous empêche d'empiler les paires — mais le SDK, lui, plafonne à **2 000 combinaisons distinctes par instrument** (`DEFAULT_MAX_CARDINALITY`, dans l'agent même que vous utilisez). Au-delà, les mesures ne sont pas jetées : le SDK **remplace leurs attributs** par `otel.metric.overflow=true` et les agrège toutes dans cette série unique.

La nuance compte pour lire un dashboard. Un `sum(reviews_created_total)` reste exact — rien n'est perdu. Mais un `sum by (app_product_id)` devient trompeur : tout ce qui a débordé se retrouve sous une seule étiquette au lieu d'être ventilé. Le seul avertissement arrive dans les **logs du service** (`… has exceeded the maximum allowed cardinality (2000).`), jamais dans Prometheus. L'étape 4 montre à quelle vitesse on s'approche de ce plafond.
{{% /expand%}}

Ce code n'appelle pourtant que des classes `io.opentelemetry.api.*` : il ne construit aucun `MeterProvider`, n'enregistre aucun exporter, ne lit aucune configuration. Comment peut-il produire des métriques ?

{{%expand "Réponse" %}}
Parce que l'API seule **ne produit rien**. `GlobalOpenTelemetry.getMeter(...)` renvoie par défaut une implémentation **no-op** : les appels `add()` et `record()` ne font littéralement rien, sans erreur ni surcoût. C'est la séparation fondamentale d'OpenTelemetry :

* l'**API** (`opentelemetry-api`) est ce que vous appelez dans votre code métier — légère, stable, sans dépendance ;
* le **SDK** est l'implémentation qui agrège, met en forme et exporte. Il est fourni ici par l'**agent Java** du Lab 2 : au démarrage de la JVM, l'agent installe son SDK dans `GlobalOpenTelemetry`, et vos appels deviennent d'un coup réels.

Conséquence pratique : une bibliothèque partagée peut s'instrumenter avec l'API sans imposer quoi que ce soit à ses utilisateurs. Et si vous retirez le `-javaagent`, l'application tourne toujours — sans métriques.

⚠️ Attention à une confusion facile : le `pom.xml` **contient** bien `opentelemetry-sdk`, mais pour une tout autre raison — les classes de masquage PII du Lab 8 en ont besoin pour compiler, et elles ne servent qu'avec le profil `starter`. Or **avoir le SDK dans le classpath ne l'active pas** : un SDK ne produit rien tant que personne ne le construit et ne l'installe. Ici, aucune ligne de l'application ne le fait ; c'est l'agent qui s'en charge, de l'extérieur.

La chaîne de types est la même dans tous les langages : **`MeterProvider` → `Meter` → instrument**. Les trois maillons n'ont ni le même rôle ni le même nombre d'exemplaires :

| | Combien | Qui le crée | Ce qu'il porte |
|---|---|---|---|
| `MeterProvider` | **un** par application | le SDK — ici, l'agent | la Resource, les exporters, la fréquence d'export, les Views |
| `Meter` | un par bibliothèque ou module | votre code | son nom : le **scope d'instrumentation** |
| instrument | autant que de mesures | votre code | le nom de la métrique, son unité |

Vous n'écrivez jamais le premier — `GlobalOpenTelemetry.getMeter(...)` est un raccourci pour `getMeterProvider().get(...)` — et c'est délibéré : votre code demande un guichet, il ne décide pas où partent les données. Vous l'avez pourtant déjà configuré au Lab 2 sans le nommer, puisque `OTEL_EXPORTER_OTLP_ENDPOINT` désigne l'exporter de ce provider, et `OTEL_SERVICE_NAME` sa Resource. C'est lui, enfin, qui explique la minute d'attente avant de voir une métrique apparaître : il collecte et exporte **à intervalle fixe, 60 s par défaut**, si bien qu'un `add()` n'envoie rien sur le réseau — il incrémente un total en mémoire, que le provider poussera au cycle suivant.

Le nom passé à `getMeter()` (`fr.k8sschool.reviews`) est le **scope d'instrumentation** : il identifie *qui* a produit la métrique, exactement comme l'`otel.scope.name` que vous verrez sur les spans au Lab 7.
{{% /expand%}}

> 💡 **Et une annotation, comme `@WithSpan` ?** Il n'y en a pas pour les métriques. Le module d'annotations d'OpenTelemetry n'en contient que trois — `@WithSpan`, `@SpanAttribute`, `@AddingSpanAttributes` (Lab 7) — et toutes produisent des **spans**. Ce n'est pas un oubli : un span commence et finit avec la méthode, une annotation suffit donc à le décrire. Un compteur métier, lui, s'incrémente à un endroit choisi du corps de la méthode, souvent sous condition — ici uniquement quand l'insertion a réussi — et avec une valeur d'attribut calculée (la note de l'avis). C'est pourquoi l'API métriques est impérative dans tous les langages. La seule voie déclarative existante est celle de Micrometer (`@Timed`, `@Counted`), qui n'accepte que des tags **statiques**.

2.  **Vérifier que l'agent est actif, puis générer du trafic.** Rien à redéployer ici : ce code est déjà dans l'image, et le Lab 5 a activé l'agent. Une commande le confirme — elle lit l'environnement réel du conteneur qui tourne :

```bash
. ./scripts/env.sh   # si ce n'est pas déjà fait dans ce terminal
kubectl exec -n otel-demo deployment/review-service -- printenv JAVA_TOOL_OPTIONS
```

Attendu : `-javaagent:/otel/opentelemetry-javaagent.jar`.

{{%expand "Rien ne s'affiche ?" %}}
L'agent n'est pas actif sur le pod en cours, et sans lui vos instruments restent no-op : aucune métrique n'arrivera, quoi que vous fassiez ensuite.

La cause la plus fréquente est d'avoir relancé `deploy.sh` depuis le Lab 5. Le script **efface délibérément** les variables posées à la main (`JAVA_TOOL_OPTIONS`, `MASK_PII`, `OTEL_INSTRUMENTATION_MICROMETER_ENABLED`) avant d'appliquer les manifestes, pour que ceux-ci restent la seule source de vérité — sans quoi un build `starter` se retrouverait avec l'agent par-dessus, soit deux SDK dans la même JVM.

Reprenez donc le [Lab 5, étape 2]({{% relref "50-otel-logs.fr.md" %}}), ou en trois commandes :

```bash
./scripts/deploy.sh
kubectl set env -n otel-demo deployment/review-service \
  JAVA_TOOL_OPTIONS="-javaagent:/otel/opentelemetry-javaagent.jar"
kubectl rollout status -n otel-demo deployment/review-service
```
{{% /expand%}}

> 💡 Pour voir l'agent se charger lui-même, et sa version :
> `kubectl logs -n otel-demo deployment/review-service | grep VersionLogger`

Une poignée de requêtes ne suffira pas : les métriques s'observent dans la **durée**. `rate(...[5m])` compare la valeur du compteur d'il y a cinq minutes à sa valeur actuelle : si vous n'avez rien envoyé pendant ces cinq minutes, les deux chiffres sont identiques, le taux vaut zéro — et le p95 calculé à partir de là affiche `NaN`. Écrivez donc un générateur, qui commence par une rafale puis ralentit progressivement pendant dix minutes — de quoi dessiner une courbe, et pas un plateau :

```bash
cat > generate-reviews.sh <<'EOF'
#!/bin/bash
# Pose des avis pendant DURATION secondes : une rafale au démarrage, puis un
# rythme qui se relâche peu à peu. Donne aux métriques de ce lab une courbe
# à observer plutôt qu'un débit constant.
. ./scripts/env.sh

DURATION=${1:-600}
MAX=${2:-400}          # plafond : ces avis restent en base
PRODUCTS=(OLJCESPC7Z 0PUK6V6EV0 1YMWWN1N4O 2ZYFJ3GM2N 66VCHSJNUP)
START=$SECONDS
END=$((START + DURATION))
NEXT_REPORT=$((START + 60))
created=0
failed=0

while [ "$SECONDS" -lt "$END" ] && [ "$((created + failed))" -lt "$MAX" ]; do
    rating=$((RANDOM % 5 + 1))
    product=${PRODUCTS[$((RANDOM % ${#PRODUCTS[@]}))]}
    n=$((created + failed + 1))
    code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
        "http://$PF_HOST:$APP_PORT/api/reviews" \
        -H "Content-Type: application/json" \
        -d "{\"productId\": \"$product\", \"rating\": $rating, \"comment\": \"lab6\",
             \"userEmail\": \"user$n@example.com\", \"userName\": \"User $n\"}")
    if [ "$code" = "201" ]; then created=$((created + 1)); else failed=$((failed + 1)); fi

    if [ "$SECONDS" -ge "$NEXT_REPORT" ]; then
        printf '%s  %d avis créés, %d échecs, %d s restantes\n' \
            "$(date +%H:%M:%S)" "$created" "$failed" "$((END - SECONDS))"
        NEXT_REPORT=$((SECONDS + 60))
    fi

    # Cadence : ~7 avis/s pendant les 15 premières secondes, puis un intervalle
    # qui s'allonge avec le temps écoulé, jusqu'à un avis toutes les 8 s.
    elapsed=$((SECONDS - START))
    if [ "$elapsed" -lt 15 ]; then
        sleep 0.15
    else
        delay=$((elapsed / 40))
        [ "$delay" -lt 1 ] && delay=1
        [ "$delay" -gt 8 ] && delay=8
        sleep "$delay"
    fi
done

printf 'Terminé : %d avis créés, %d échecs.\n' "$created" "$failed"
EOF
chmod +x generate-reviews.sh
```

Lancez-le **dans un second terminal**, et laissez-le tourner pendant tout le lab :

```bash
. ./scripts/env.sh   # ce terminal-là aussi a besoin des variables
./generate-reviews.sh
```

Il affiche son compteur chaque minute :

```text
10:47:01  145 avis créés, 0 échecs, 540 s restantes
10:48:01  185 avis créés, 0 échecs, 480 s restantes
10:49:01  204 avis créés, 0 échecs, 420 s restantes
```

La décélération se lit déjà dans ces chiffres : 145 avis la première minute, 40 la deuxième, 19 la troisième. Au bout des dix minutes, comptez **environ 265 avis** — c'est ce que vous retrouverez dans le compteur, et la pente que dessinera `rate()` dans Grafana.

> 💡 **Ces avis restent en base**, et `GET /api/reviews` renvoie la table entière : quelques centaines de lignes ralentissent un peu ce point d'entrée pour les labs suivants. Ils portent tous le commentaire `lab6`, ce qui permet de les retirer après coup :
>
> ```bash
> kubectl exec -n otel-demo deploy/postgresql -- \
>   psql -U root -d otel -tAc "delete from reviews where comment = 'lab6'"
> ```

3.  **Retrouver les métriques dans Prometheus** (`http://$PF_HOST:$PROM_PORT/`), en laissant passer une minute après vos requêtes — le temps d'un cycle d'export. Cherchez ce que le préfixe `reviews_` propose : vos deux instruments y sont, mais **pas sous le nom que vous avez écrit**. Pourquoi ?

{{%expand "Réponse" %}}
Vous trouvez :

* `reviews_created_total` — votre compteur ;
* `reviews_creation_duration_milliseconds_bucket`, `_sum` et `_count` — votre histogramme.

Deux traductions ont eu lieu entre votre code et Prometheus :

* les **points** deviennent des `_` (`reviews.created` → `reviews_created`) : le point n'est pas un caractère légal dans un nom de série Prometheus ;
* deux **suffixes** ont été ajoutés. `_total` marque un compteur monotone, c'est la convention Prometheus. Et `_milliseconds` vient de l'unité que vous avez déclarée dans le code (`.setUnit("ms")`) : la traduction OTLP → Prometheus développe l'unité et l'accole au nom. Déclarer une unité n'est donc pas décoratif — cela change le nom de la série.

Chemin parcouru : API OTel → SDK de l'agent → OTLP → collecteur → exporter `otlphttp/prometheus` → Prometheus. **Retenez le principe** : le nom que vous lisez dans Prometheus n'est jamais tout à fait celui que vous avez écrit dans le code. Cherchez par préfixe, pas par nom exact.
{{% /expand%}}

Comptez enfin **combien de métriques ce service expose en tout**, et notez le nombre — la Partie 2 vous demandera de le comparer :

```promql
count(count by (__name__)({job="otel-demo/review-service"}))
```

Une cinquantaine : vos deux instruments, et tout ce que l'agent produit seul (JVM, HTTP, pool de connexions).

4.  **Tracer la latence p95** de création d'un avis, et **compter les avis par note** :

{{%expand "Réponse" %}}
```promql
histogram_quantile(0.95, sum(rate(reviews_creation_duration_milliseconds_bucket[5m])) by (le))
```

```promql
sum by (app_review_rating) (reviews_created_total)
```

La seconde requête marche parce que le code a posé un **attribut** sur chaque point de mesure :

```java
private static final AttributeKey<Long> RATING = AttributeKey.longKey("app.review.rating");
...
reviewsCreated.add(1, Attributes.of(RATING, (long) review.getRating()));
```

Un attribut de métrique devient un **label** Prometheus, et donc une **série temporelle par valeur distincte**. Une note vaut 1 à 5 : 5 séries, c'est gratuit. Le même code avec `user.email` à la place créerait une série par utilisateur — c'est l'**explosion de cardinalité**, la première cause de mort d'un Prometheus. Les identifiants vont dans les **traces** (où ils coûtent un attribut sur un span), jamais dans les métriques.

**Et si on en mettait deux ?** C'est la même méthode, avec deux paires :

```java
private static final AttributeKey<String> PRODUCT = AttributeKey.stringKey("app.product.id");
...
Attributes.of(RATING,  (long) review.getRating(),
              PRODUCT, review.getProductId());
```

Vous obtiendriez alors des séries à deux labels, `reviews_created_total{app_review_rating="5", app_product_id="OLJCESPC7Z"}`. Mais leur nombre est le **produit** des valeurs, jamais leur somme — et le catalogue de la démo compte 10 produits :

| | note seule | note + produit |
|---|---|---|
| le compteur | 5 séries | 5 × 10 = **50** |
| l'histogramme (16 seaux) | 80 séries | 5 × 10 × 16 = **800** |

Le SDK ne crée que les combinaisons réellement rencontrées, mais le plafond est bien celui-là. Sur un vrai catalogue de 50 000 références, cette même ligne donnerait 250 000 séries pour le compteur et 4 millions pour l'histogramme. **Un attribut ne s'ajoute que si l'on sait par combien il multiplie** — et un histogramme multiplie déjà par son nombre de seaux.
{{% /expand%}}

### Partie 2 — Et l'instrumentation Micrometer que vous avez déjà ?

Vous venez d'écrire de l'OpenTelemetry natif. Mais une application Spring en production a déjà, elle, des dizaines de meters **Micrometer** — la façade métriques de Spring Boot, fournie par Actuator. Faut-il tout réécrire ? Non.

5.  **Lire le meter Micrometer** du même service, qui chronomètre exactement le même bloc de code que votre histogramme :

```java
this.reviewCreationTimer = Timer.builder("reviews.creation.time")
        .description("Time spent creating a review, measured by Micrometer")
        .publishPercentileHistogram()
        .register(registry);
```

Cherchez `reviews_creation_time` dans Prometheus : **il n'y est pas**. Pourquoi, et que faut-il faire ?

{{%expand "Réponse" %}}
L'agent Java sait faire le pont — chaque meter Micrometer devient une métrique OTLP — mais ce **bridge est désactivé par défaut**, pour éviter les doublons avec les métriques que Spring Boot exporte parfois déjà de son côté. Il s'active par une variable d'environnement :

```bash
kubectl set env -n otel-demo deployment/review-service \
  OTEL_INSTRUMENTATION_MICROMETER_ENABLED=true
kubectl rollout status -n otel-demo deployment/review-service
```

Un meter qui reste invisible faute d'avoir activé son bridge est un **classique du debug OTel** : le code est juste, la configuration ne l'est pas.
{{% /expand%}}

6.  **Vérifier que le générateur tourne toujours** dans son terminal — le rollout de l'étape précédente a coupé ses requêtes le temps du redémarrage, et ses dix minutes ont pu s'écouler (`./generate-reviews.sh` le relance). Puis observer, après un cycle d'export, ce qui est apparu dans Prometheus :

{{%expand "Réponse" %}}
`reviews_creation_time_seconds_bucket`, `_sum`, `_count` — le pendant Micrometer de votre histogramme. Notez l'unité : **secondes**, là où votre instrument OTel produisait des `_milliseconds`. Le même bloc de code, chronométré deux fois, à deux échelles : un `Timer` Micrometer publie toujours en secondes.

Mais surtout, regardez tout ce qui est arrivé avec. Relancez le comptage de l'étape 3 :

```promql
count(count by (__name__)({job="otel-demo/review-service"}))
```

Le nombre a **plus que doublé** — d'une cinquantaine de métriques à plus de cent trente — pour un seul `Timer` écrit à la main. Tout le reste, c'est le patrimoine **Actuator** que Spring Boot instrumente pour vous, et que le pont emporte avec : `hikaricp_connections_*` (le pool de connexions), `jvm_gc_pause_seconds_*`, `tomcat_sessions_*`, `logback_events_total`, `spring_data_repository_invocations_seconds_*`, `application_ready_time_seconds`…

C'est tout l'intérêt du pont : **vous ne réécrivez pas votre instrumentation existante**. Vous branchez l'agent, et le patrimoine Micrometer de l'application — le vôtre et celui d'Actuator — part en OTLP avec le reste.

Le revers se lit dans la même liste, et c'est **la raison pour laquelle ce pont est fermé par défaut** : une bonne partie de ces séries mesure ce que l'agent mesurait déjà, sous d'autres noms.

| Mesuré par l'agent (convention OTel) | Le doublon Micrometer/Spring |
|---|---|
| `http_server_request_duration_seconds_*` | `http_server_requests_seconds_*` |
| `db_client_connections_usage` | `hikaricp_connections_active`, `jdbc_connections_active` |
| `jvm_gc_duration_seconds_*` | `jvm_gc_pause_seconds_*` |
| `jvm_thread_count` | `jvm_threads_live`, `jvm_threads_daemon` |

Deux mesures de la même chose, stockées deux fois. En production il faut trancher : garder le pont fermé et s'en tenir aux conventions OTel, ou l'ouvrir et écarter les doublons dans le collecteur (processor `filter`, cf. Lab 3).

Alors, API OpenTelemetry ou Micrometer ?

* **API OpenTelemetry** : la même dans tous les langages, aucun bridge à activer, et le seul chemin pour les **traces** et les **logs**. À privilégier pour du code neuf.
* **Micrometer** : ce que votre application Spring a déjà. À garder — et à faire sortir en OTLP par le pont plutôt qu'à réécrire.

Les deux cohabitent sans problème dans une même JVM, comme ici : ce service exporte les deux.
{{% /expand%}}

> 💡 **Et si je n'avais pas d'agent ?** Micrometer sait exporter tout seul, sans une ligne d'OpenTelemetry dans la JVM : la dépendance `micrometer-registry-otlp` et une propriété Spring (`management.otlp.metrics.export.url`) envoient les meters au collecteur en OTLP. `micrometer-registry-prometheus` fait l'équivalent en mode **pull**, en exposant `/actuator/prometheus` à scraper.
>
> Deux réserves avant de choisir cette voie. Le **Spring Boot Starter** du Lab 2 n'a, lui, aucun pont Micrometer — son jar ne contient pas une seule classe Micrometer : il trace et journalise, mais laisse vos meters sur place. Et un registry n'exporte que des **métriques** : ni traces, ni logs, ni contexte partagé. Vous obtenez trois tuyaux séparés au lieu de la chaîne unique que ces labs construisent, et vous perdez la corrélation des Labs 4 et 5.
>
> Quant à `review-service`, il n'embarque **aucun** registry d'export et n'expose qu'`/actuator/health` : sans le pont de l'agent, ses meters Micrometer existent bel et bien en mémoire — et ne sont visibles nulle part.

### Partie 3 — Dériver une métrique depuis les spans (connector `count`)

7.  **Ajouter le connector `count`** : comme au Lab 3, un fichier de values, `manifests/60-otel-metrics-values.yaml`. Il doit compter les spans **en erreur** et exposer le résultat en métrique `app.spans.errors`.

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

Comme au Lab 3, relisez la ConfigMap pour voir ce que Helm a réellement produit de vos values :

```bash
kubectl get configmap otel-collector-agent -n otel-demo -o jsonpath='{.data.relay}' | less
```

Ou, pour aller droit au connector que vous venez d'ajouter :

```bash
kubectl get configmap otel-collector-agent -n otel-demo -o jsonpath='{.data.relay}' \
  | grep -B1 -A6 -E '^\s+count:'
```

```yaml
connectors:
  count:
    spans:
      app.spans.errors:
        conditions:
        - status.code == STATUS_CODE_ERROR
        description: Number of spans with ERROR status
```

C'est le seul endroit qui dit la vérité sur la configuration en vigueur : vos values sont un *calque*, la ConfigMap est ce que le collecteur lit au démarrage.

8.  **Provoquer des erreurs et vérifier :** créez un avis pour un produit inexistant (le service échoue en 500) :

```bash
curl -s -X POST http://$PF_HOST:$APP_PORT/api/reviews \
  -H "Content-Type: application/json" \
  -d '{"productId": "DOESNOTEXIST", "rating": 5, "comment": "?", "userEmail": "x@example.com", "userName": "X"}'
```

Dans Prometheus, cherchez `app_spans_errors_total` : votre première métrique **dérivée des traces**, sans une ligne de code.

## Livrable

Dans Grafana ou Prometheus : le graphe de latence p95 de création d'un avis + le compteur métier des avis créés, ventilé par note + la métrique dérivée `app_spans_errors_total`.
