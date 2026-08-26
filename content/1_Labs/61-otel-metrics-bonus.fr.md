---
title: 'Lab 6 bonus — Une métrique qui va et vient'
date: 2026-08-26T10:00:00+02:00
draft: false
weight: 61
tags: ["OpenTelemetry", "métriques", "Prometheus", "PromQL", "connector"]
---

Page de lecture : rien à construire, rien à déployer. Elle explique un comportement déroutant du Lab 6 — la métrique `app_spans_errors_total` apparaît, puis disparaît, puis revient — et ce qu'il révèle du modèle de données des métriques.

## 1. Le symptôme

Vous provoquez une erreur, la métrique apparaît dans Prometheus. Vous revenez dix minutes plus tard, et la même requête répond :

```text
Empty query result
This query returned no data.
```

Rien n'est cassé, rien n'est perdu. Trois mécanismes se superposent, et chacun est utile à connaître.

## 2. Delta ou cumulative : ce que porte un point

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

## 3. Pourquoi elle sort des résultats

Une requête **instantanée** — `app_spans_errors_total` sans fonction de fenêtre — ne cherche pas la valeur à la milliseconde près. Elle prend **le dernier point situé dans les cinq minutes qui précèdent**, un paramètre de Prometheus nommé `query.lookback-delta`.

Or le connector cesse d'émettre dès que les erreurs s'arrêtent. Passé cinq minutes, plus aucun point dans la fenêtre : la série n'est plus retournée.

Elle n'est pas supprimée pour autant. Sur le Prometheus de la formation, les données sont conservées **une semaine** (`storage.tsdb.retention.time`).

Le contraste avec votre compteur applicatif est net. Relevé sur 30 minutes, au pas d'une minute :

| Métrique | Points relevés |
|---|---|
| `reviews_created_total` (SDK, cumulative) | **31** sur 30 — un à chaque pas |
| `app_spans_errors_total` (connector, delta) | **15 à 18** — la série est trouée |

**Une métrique dérivée des traces n'existe que tant qu'il se passe quelque chose.**

## 4. La retrouver

Demandez une **fenêtre** plutôt qu'un instant :

```promql
last_over_time(app_spans_errors_total[1h])
```

qui renvoie la dernière valeur connue de chaque série sur l'heure écoulée. L'onglet **Graph** de Prometheus fait la même chose visuellement : les points passés y restent visibles, trous compris.

⚠️ **Faux ami :** `count_over_time` compte les **points de mesure**, pas les erreurs. Sur une même série, il affiche 18 là où le compteur vaut 3. La requête « marche », et le nombre n'a rien à voir avec ce que vous cherchez.

## 5. Ce que le cumul ne survit pas

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

## 6. Compter des requêtes plutôt que des spans

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
