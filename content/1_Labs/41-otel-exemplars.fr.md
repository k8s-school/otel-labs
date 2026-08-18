---
title: 'Lab 4.1 — Exemplars : du point de métrique à la trace'
date: 2026-08-18T10:00:00+02:00
draft: false
weight: 41
tags: ["Grafana", "exemplars", "Prometheus", "Jaeger", "heatmap"]
---

Le Lab 4 s'est arrêté sur une frustration : le panel « Latence p95 » dit que le service est lent, mais pas **quelle requête** l'a été. Une métrique est une agrégation — « 30 requêtes, p95 à 400 ms » ne désigne personne.

Les **exemplars** sont le chaînon manquant. Ici, rien à construire : on lit un dashboard que la démo livre exprès pour ça.

## Prérequis

* Lab 4 terminé.
* Les accès ouverts (`./scripts/open-ui.sh`) et les variables chargées : `. ./scripts/env.sh`.

## Étapes

1.  **Ouvrir le dashboard « Cart Service Exemplars »** livré par la démo :

```bash
. ./scripts/env.sh   # si ce n'est pas déjà fait dans ce terminal
echo "http://$PF_HOST:$UI_PORT/grafana/d/ce6sd46kfkglca"
```

Il porte sur le service **`cart`** (le panier de la boutique), et non sur le vôtre — l'étape 5 explique pourquoi.

2.  **Ce qu'est un exemplar.** C'est une mesure individuelle conservée **à côté** de l'agrégat, avec le `trace_id` de la requête qui l'a produite :

```text
série    : app_cart_get_cart_latency_seconds_bucket{service_name="cart"}
exemplar : value = 0.001026 (s)   labels = {trace_id: "7d241ae2…", span_id: "81f9a94c…"}
```

La série dit « il y a eu tant de requêtes dans ce seau » ; l'exemplar ajoute « et en voici une, la voilà ».

3.  **Le câblage qui rend le clic possible.** Un `trace_id` dans une métrique ne sert à rien si Grafana ne sait pas **où** aller chercher la trace. C'est le rôle d'une ligne de configuration de la datasource Prometheus, vue au Lab 4 :

```bash
curl -s http://$PF_HOST:$UI_PORT/grafana/api/datasources/name/Prometheus \
  | grep -o '"exemplarTraceIdDestinations":\[[^]]*\]'
```

```json
"exemplarTraceIdDestinations":[{"datasourceUid":"webstore-traces","name":"trace_id"}, ...]
```

Traduction : « quand tu rencontres un `trace_id` dans une métrique, va ouvrir la trace dans la datasource dont l'UID est `webstore-traces` » — c'est-à-dire Jaeger. Sans cette ligne, Grafana saurait qu'il tient un identifiant, mais pas où aller. La même configuration se lit dans l'interface, sur la page de la datasource, et à la source dans la ConfigMap qui la provisionne : `kubectl get configmap grafana-datasources -n otel-demo -o yaml`.

4.  **Lire la première heatmap.** Le dashboard a deux rangées, une par opération du panier (*GetCart*, *AddItem*), et dans chacune deux vues de la **même** mesure. Commençons par la première, **« GetCart Latency Heatmap with Exemplars »** :

```promql
sum by(le) (rate(app_cart_get_cart_latency_seconds_bucket[$__rate_interval]))
```

C'est la requête du p95 du Lab 4 **sans le `histogram_quantile`** — et c'est tout l'intérêt : au lieu de résumer la distribution en un seul chiffre, on l'affiche entière.

* **En abscisse, le temps**, comme sur n'importe quel graphe.
* **En ordonnée, les seaux de latence** — les valeurs du label `le` de la métrique (`le` = *less or equal*, la borne supérieure du seau). Attention à l'unité : cette métrique est en **secondes**, l'axe affiche donc `0.005` pour 5 ms.
* **La couleur d'une cellule, le nombre de requêtes** tombées dans ce seau pendant cet intervalle. Plus c'est vif, plus il y en a eu.

Une colonne de la heatmap, lue de bas en haut, c'est donc la **distribution des latences à cet instant** : où se concentre le gros du trafic, et ce qui traîne au-dessus. Là où le panel voisin réduit chaque instant à un point — le p95 —, la heatmap montre **toute la population**. C'est la même métrique, le même `sum by(le)`, et deux lectures.

> 💡 Le `rate(...)` n'a pas disparu : les seaux sont des **compteurs cumulés depuis le démarrage du service**. Sans lui, la heatmap afficherait la distribution *depuis toujours*, une image qui ne bouge quasiment plus. Avec lui, chaque colonne ne montre que ce qui vient de se passer. `$__rate_interval` est la variable de Grafana qui adapte la fenêtre au zoom du dashboard.

5.  **Repérer les exemplars.** Ils ne sont pas *sur* la courbe : ce sont des marqueurs à part, de petits **carrés magenta** sur la heatmap, de petits **losanges verts** sur la courbe du p95 juste à côté (« 95th Pct Cart GetCart Latency with Exemplars »).

Chacun est posé à **sa propre valeur** — le plus souvent *sous* la courbe du p95, parfois au-dessus. Rien d'anormal : la courbe est un p95, donc dans le haut de la distribution, tandis qu'un exemplar est une requête tirée au hasard, généralement plus rapide.

**Survolez un marqueur** : une infobulle donne la valeur, le `trace_id` et un lien. **Cliquez** : Jaeger s'ouvre sur cette requête précise. Au lieu de chercher dans Jaeger une trace qui ressemblerait au symptôme, c'est le symptôme qui vous donne son identifiant.

> 💡 **La seule différence avec vos panels du Lab 4 tient en une case cochée** : dans les options de la requête, *Exemplars*. Elle vaut `"exemplar": true` dans le JSON du panel — allez le vérifier, *Panel → Inspect → Panel JSON*.

6.  **Pourquoi cette métrique en porte, et pas les vôtres.** `app_cart_get_cart_latency_seconds_bucket` est produite par le **SDK OpenTelemetry du service `cart`** : au moment où il enregistre la durée, le SDK a le `trace_id` du span en cours sous la main, et l'attache à la mesure. Vos panels, eux, affichent `traces_span_metrics_*`, que le **collecteur** recalcule après coup à partir des spans — il ne joint aucun `trace_id`, sauf si on le lui demande.

{{%expand "Ce qu'il faudrait pour que vos panels en aient" %}}
Trois conditions doivent être réunies ; la démo en remplit deux :

1. **Prometheus doit les stocker** — il est démarré avec `--enable-feature=exemplar-storage` (visible dans `/api/v1/status/flags`) ; sans ce drapeau, il les jette à l'ingestion. ✔
2. **La datasource doit savoir où ouvrir la trace** — c'est le `"exemplarTraceIdDestinations": [{"datasourceUid": "webstore-traces"}]` de l'étape 3 : l'UID de Jaeger, et rien d'autre, fait le lien. ✔
3. **La métrique doit en porter** — et c'est là que ça coince : `spanmetrics` est configuré avec `{}`, et cette configuration par défaut ne produit **aucun** exemplar. ✘

Rien n'est cassé, il manque une ligne. Le connector sait le faire, l'option est simplement désactivée par défaut :

```yaml
opentelemetry-collector:
  config:
    connectors:
      spanmetrics:
        exemplars:
          enabled: true
```

Appliquée sur le modèle du Lab 3 (un fichier de values de plus, empilé sur les précédents), elle rendrait votre panel « Latence p95 » cliquable jusqu'à la trace, pour le service de votre choix. Deux réserves alors : un exemplar n'est gardé **que le temps d'un cycle d'export**, et `max_per_data_point` en limite le nombre à 5 par point de mesure.
{{% /expand%}}

7.  **Le constater sans Grafana.** L'API de Prometheus répond directement :

```bash
. ./scripts/env.sh   # si ce n'est pas déjà fait dans ce terminal
curl -s -G "http://$PF_HOST:$PROM_PORT/api/v1/query_exemplars" \
  --data-urlencode 'query=app_cart_get_cart_latency_seconds_bucket' \
  --data-urlencode "start=$(date -d '-1 hour' +%s)" --data-urlencode "end=$(date +%s)" \
  | head -c 400
```

Vous y lisez des `trace_id` en clair. Remplacez maintenant le nom par `traces_span_metrics_duration_milliseconds_bucket`, la métrique de vos panels : la réponse est `{"status":"success","data":[]}`.

## À retenir

Un exemplar est le pont entre deux signaux : la **métrique** repère l'incident et le situe dans le temps, l'**exemplar** désigne une requête précise, la **trace** l'explique. C'est le trajet complet que fait un astreinte — et il tient en un clic quand la chaîne est câblée de bout en bout : SDK qui attache le `trace_id`, Prometheus qui le stocke, datasource qui sait où ouvrir la trace.

La lecture détaillée du PromQL de ces panels — les seaux, le p95, la heatmap — est dans le [Lab 4 bonus]({{% relref "42-otel-grafana-bonus" %}}).
