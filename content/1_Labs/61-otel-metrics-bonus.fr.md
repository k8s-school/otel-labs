---
title: 'Lab 6 bonus — Une métrique qui va et vient'
date: 2026-08-26T10:00:00+02:00
draft: false
weight: 61
tags: ["OpenTelemetry", "métriques", "Prometheus", "PromQL", "connector"]
---

Cette page fait naître une métrique **sans écrire une ligne de code** — le collecteur la dérive des spans qu'il voit passer — puis explique le comportement déroutant qui s'ensuit : `app_spans_errors_total` apparaît, disparaît, revient. Ce qu'il révèle du modèle de données des métriques vaut le détour.

## 1. Dériver une métrique depuis les spans — le connector `count`

Aucun des labs précédents n'en dépend, et le fichier de values suit exactement le modèle du Lab 3.


1.  **Ajouter le connector `count`** : comme au Lab 3, un fichier de values, `manifests/60-otel-metrics-values.yaml`. Il doit compter les spans **en erreur** et exposer le résultat en métrique `app.spans.errors`.

    La [documentation du connector `count`](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/connector/countconnector/README.md) donne la structure attendue (`spans:`, puis une entrée par métrique avec ses `conditions:`) ; la condition elle-même s'écrit en **OTTL**, dont les fonctions sont [répertoriées ici](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/pkg/ottl/ottlfuncs/README.md).

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

2.  **Provoquer des erreurs et vérifier :** créez un avis pour un produit inexistant (le service échoue en 500) :

```bash
curl -s -X POST http://$PF_HOST:$APP_PORT/api/reviews \
  -H "Content-Type: application/json" \
  -d '{"productId": "DOESNOTEXIST", "rating": 5, "comment": "?", "userEmail": "x@example.com", "userName": "X"}'
```

Dans Prometheus, cherchez `app_spans_errors_total` : votre première métrique **dérivée des traces**, sans une ligne de code. Ventilez-la par service :

```promql
sum by (service_name) (app_spans_errors_total)
```

Votre unique requête a fait monter la série de `review-service` de **3**. Pourquoi pas de 1 ?

{{%expand "Réponse" %}}
Parce que le connector compte des **spans**, pas des requêtes. L'exception remonte toute la pile d'appels, et chaque span qu'elle traverse se termine en erreur :

```text
POST /api/reviews          🔴 500   le span serveur
└── product-catalog.lookup 🔴       le span manuel du code (Lab 7)
    └── GET                🔴 500   l'appel HTTP vers le frontend
```

**Allez voir la trace dans Jaeger** (`http://$PF_HOST:$UI_PORT/jaeger/ui/`). Dans le panneau de recherche :

* *Service* : `review-service`
* *Operation* : `POST /api/reviews`
* *Tags* : `error=true` — c'est ce filtre qui compte, sans lui votre trace se noie parmi les requêtes réussies du générateur.

Cliquez sur **Find Traces** : la vôtre est en tête, marquée d'une pastille rouge. Dépliez-la, et vous constaterez que l'erreur n'est pas restée chez vous. Le `frontend` a été appelé, puis `product-catalog` : eux aussi ont leurs spans en erreur, et le total dépasse largement 3.

Relevé sur une de ces traces : **9 spans, dont 8 en erreur** — 3 dans `review-service`, 4 dans le `frontend`, 1 dans `product-catalog`. `sum(app_spans_errors_total)` monte donc de 8 pour une seule requête, quand la série de votre service ne monte que de 3.

Le neuvième span, celui de la base de `product-catalog`, n'est **pas** en erreur : la requête SQL s'est exécutée normalement, elle n'a simplement rien trouvé. Un échec **métier** ne devient une erreur **technique** qu'à l'endroit où du code décide de lever une exception — ici, dans `review-service`.

C'est le point à retenir sur cette métrique : elle mesure la **propagation** d'une panne à travers le système, pas le nombre de requêtes ratées. Pour compter des requêtes, il faudrait ne retenir que les spans **serveur** — un seul par service et par requête. C'est l'objet de la [dernière section de cette page](#7-compter-des-requêtes-plutôt-que-des-spans), qui l'ajoute en quatre lignes de YAML.
{{% /expand%}}

> 💡 **Si vous revenez sur cette métrique plus tard, elle aura disparu.** Elle n'est alimentée que lorsqu'une erreur survient, et une requête instantanée ne regarde que les cinq dernières minutes. Vos données sont pourtant bien là : ouvrez l'onglet **Graph** sur la dernière heure, ou demandez la dernière valeur connue avec `last_over_time(app_spans_errors_total[1h])`.
>
> Le pourquoi — delta, cumulative, et ce que le collecteur garde en mémoire — occupe le reste de cette page.

## 2. Le symptôme

Vous provoquez une erreur, la métrique apparaît dans Prometheus. Vous revenez dix minutes plus tard, et la même requête répond :

```text
Empty query result
This query returned no data.
```

Rien n'est cassé, rien n'est perdu. Trois mécanismes se superposent, et chacun est utile à connaître.

## 3. Delta ou cumulative : ce que porte un point

Une métrique se transporte de deux façons, et c'est un choix de l'émetteur :

| | Ce que porte chaque point de mesure |
|---|---|
| **Cumulative** | le total depuis le démarrage — le compteur ne fait que monter |
| **Delta** | l'incrément depuis l'export précédent |

Le **SDK OpenTelemetry** exporte en cumulative : toutes les 60 secondes, il republie le total courant, **même s'il n'a pas bougé**. C'est le cas de votre `reviews_created_total`.

Le **connector `count`**, lui, émet en **delta** : à chaque cycle il annonce « tant de spans en erreur depuis la dernière fois ». Et quand il n'y en a eu aucun, il n'envoie **rien du tout** — pas même un zéro.

Prometheus, de son côté, ne sait travailler qu'en cumulatif : `rate()` calcule une pente, ce qui suppose une courbe qui monte. C'est tout le rôle du processor **`deltatocumulative`** du Lab 6 : il additionne les deltas au fil de l'eau pour reconstituer un total.

Sans lui, l'endpoint OTLP de Prometheus rejette les points. Vérifié en retirant le processor du pipeline sur le cluster de la formation — voici ce que le collecteur écrit alors, une ligne par export :

```text
error  Exporting failed. Dropping data.
  "otelcol.component.id": "otlphttp/prometheus"
  "error": "not retryable error: Permanent error: … request to
            http://prometheus:9090/api/v1/otlp/v1/metrics
            responded with HTTP Status Code 500"
  "dropped_items": 1
```

Deux mots comptent dans ce message. **`Permanent error`** : le collecteur ne réessaiera pas, il n'y a rien à espérer d'un nouvel envoi. Et **`Dropping data`** : les points sont perdus, définitivement. Côté Grafana, vous ne verriez qu'un panel vide — c'est un exercice de débogage classique, et le réflexe qu'il enseigne vaut pour toute la chaîne : **quand une donnée manque, lisez d'abord les logs du composant qui l'émet**.

### Le processor est-il vraiment obligatoire ?

Oui **ici**, mais ce n'est pas une bonne pratique du connector `count` : c'est la **destination** qui l'impose. Si vous exportiez vers un backend qui parle nativement delta — Datadog, une passerelle StatsD — le processor serait inutile, et il faudrait même faire l'inverse (`cumulativetodelta` existe pour cela).

Et le collecteur n'est pas le seul endroit possible. Prometheus 3 sait faire la conversion lui-même, derrière un drapeau :

```text
--enable-feature=otlp-deltatocumulative
```

Il n'est pas activé sur le Prometheus de la formation — seul `exemplar-storage` l'est — d'où l'échec sans le processor.

Alors, où convertir ? **Dans le collecteur**, pour trois raisons : l'état d'accumulation reste près de la source, la même configuration fonctionne quel que soit le backend, et le drapeau Prometheus est encore **expérimental**. Avec une réserve, développée au § 5 : le collecteur garde cet état en mémoire, donc un redémarrage de son pod remet les compteurs dérivés à zéro. Côté Prometheus, l'état serait persisté — c'est vraisemblablement la raison d'être de ce drapeau.

## 4. Pourquoi elle sort des résultats

Une requête **instantanée** — `app_spans_errors_total` sans fonction de fenêtre — ne cherche pas la valeur à la milliseconde près. Elle prend **le dernier point situé dans les cinq minutes qui précèdent**, un paramètre de Prometheus nommé `query.lookback-delta`.

Or le connector cesse d'émettre dès que les erreurs s'arrêtent. Passé cinq minutes, plus aucun point dans la fenêtre : la série n'est plus retournée.

Elle n'est pas supprimée pour autant. Sur le Prometheus de la formation, les données sont conservées **une semaine** (`storage.tsdb.retention.time`).

Le contraste avec votre compteur applicatif est net. Relevé sur 30 minutes, au pas d'une minute :

| Métrique | Points relevés |
|---|---|
| `reviews_created_total` (SDK, cumulative) | **31** sur 30 — un à chaque pas |
| `app_spans_errors_total` (connector, delta) | **15 à 18** — la série est trouée |

**Une métrique dérivée des traces n'existe que tant qu'il se passe quelque chose.**

## 5. La retrouver

Demandez une **fenêtre** plutôt qu'un instant :

```promql
last_over_time(app_spans_errors_total[1h])
```

qui renvoie la dernière valeur connue de chaque série sur l'heure écoulée. L'onglet **Graph** de Prometheus fait la même chose visuellement : les points passés y restent visibles, trous compris.

⚠️ **Faux ami :** `count_over_time` compte les **points de mesure**, pas les erreurs. Sur une même série, il affiche 18 là où le compteur vaut 3. La requête « marche », et le nombre n'a rien à voir avec ce que vous cherchez.

## 6. Ce que le cumul ne survit pas

Le total reconstitué par `deltatocumulative` vit **dans la mémoire du collecteur**. Deux conséquences :

* le collecteur de la démo est un **DaemonSet** — chaque `helm upgrade` redémarre son pod, et les compteurs dérivés repartent de zéro ;
* le processor ne garde pas indéfiniment l'état d'une série inactive.

Le second point se mesure. Relevé sur le cluster de la formation, en provoquant des erreurs puis en laissant le service tranquille :

```text
après 2 requêtes en erreur            : 6      (2 x 3 spans)
après 1 requête de plus               : 12     le cumul fonctionne
--- 7 minutes sans aucune erreur ---
                                        absente  (sortie des requêtes instantanées)
après 1 nouvelle requête              : 3      ← reparti de zéro
```

Le compteur ne reprend pas à 15 : il **repart de zéro**. Le processor avait oublié la série faute de nouveaux deltas.

C'est une différence de fond avec un compteur applicatif, dont le total est tenu par le SDK dans la mémoire du service et republié à chaque cycle, actif ou non. En pratique, cela veut dire qu'une métrique dérivée **n'est pas un compteur au long cours** : sa valeur absolue ne raconte rien. On la lit avec `rate()` ou `increase()`, qui détectent ces remises à zéro et les traitent correctement — là où l'œil, lui, y verra une baisse inexpliquée.

## 7. Compter des requêtes plutôt que des spans

Le Lab 6 le montre : une seule requête en échec fait monter `app_spans_errors_total` de **3** pour `review-service`, parce que l'exception traverse trois spans. Pour compter des **requêtes**, il faut ne retenir que les spans **serveur** — il n'y en a qu'un par service et par requête.

C'est la seule section de cette page où il y a quelque chose à faire, et c'est court. Un même connector peut produire **plusieurs métriques** : il suffit d'une seconde entrée sous `spans:`. Le fichier de référence est [`61-otel-metrics-values.yaml`](../61-otel-metrics-values.yaml) :

```yaml
opentelemetry-collector:
  config:
    connectors:
      count:
        spans:
          app.requests.errors:
            description: "Number of failed server requests"
            conditions:
              - status.code == STATUS_CODE_ERROR and kind == SPAN_KIND_SERVER
```

`kind == SPAN_KIND_SERVER` ne retient que les spans de **requêtes reçues** : un service qui échoue en appelant un autre ne compte pas ici, seul l'échec qu'il renvoie à son propre appelant est compté.

Il **s'empile** sur celui du Lab 6 : Helm fusionne les maps, donc `app.requests.errors` s'ajoute à `app.spans.errors` sans la remplacer. Rien d'autre à redéclarer — ni les pipelines, ni `deltatocumulative` :

```bash
cp content/1_Labs/61-otel-metrics-values.yaml manifests/

helm upgrade otel-demo open-telemetry/opentelemetry-demo \
  --version 0.40.9 -n otel-demo \
  -f manifests/values-training.yaml \
  -f manifests/30-otel-collector-values.yaml \
  -f manifests/60-otel-metrics-values.yaml \
  -f manifests/61-otel-metrics-values.yaml
kubectl rollout status daemonset/otel-collector-agent -n otel-demo
```

Provoquez trois erreurs comme à l'étape 8 du Lab 6, patientez un cycle d'export, et comparez les deux métriques :

```promql
app_requests_errors_total{service_name="review-service"}
app_spans_errors_total{service_name="review-service"}
```

```text
app_requests_errors_total  3   ← une par requête
app_spans_errors_total     9   ← trois spans par requête
```

Les deux répondent à deux questions différentes — « combien de requêtes ont échoué ? » et « quelle est l'ampleur de la panne dans le système ? » — et il vaut mieux savoir laquelle on lit.
