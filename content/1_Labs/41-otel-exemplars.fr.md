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

Traduction : « quand tu rencontres un `trace_id` dans une métrique, va ouvrir la trace dans la datasource dont l'UID est `webstore-traces` » — c'est-à-dire Jaeger. Sans cette ligne, Grafana saurait qu'il tient un identifiant, mais pas où aller. La même configuration se lit dans l'interface, sur la page de la datasource, et à la source dans la ConfigMap qui la provisionne — pour Prometheus, le fichier `default.yaml` :

```bash
kubectl get configmap grafana-datasources -n otel-demo -o jsonpath='{.data.default\.yaml}'
```

```yaml
    jsonData:
      timeInterval: "60s"
      exemplarTraceIdDestinations:
        - datasourceUid: webstore-traces
          name: trace_id
```

`name: trace_id` est le nom de l'étiquette que Prometheus attache à un exemplar : c'est là que Grafana va lire l'identifiant de trace.

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

Chacun est posé à **sa propre valeur** — le plus souvent *sous* la courbe du p95, parfois au-dessus. Ce n'est pas un tirage au hasard parmi toutes les requêtes, et le mécanisme réel explique mieux ce que vous voyez : le SDK garde **un échantillon par seau** de l'histogramme. Chaque seau qui a reçu du trafic conserve donc ses requêtes témoins, et Grafana les affiche toutes, seaux confondus.

> 💡 **La heatmap et la courbe affichent les mêmes exemplars**, tous seaux confondus — et non, la courbe du p95 ne montre pas seulement les requêtes du seau où tombe le p95. Quand la case *Exemplars* est cochée, Grafana envoie l'expression du panel à l'API `query_exemplars`, qui n'en retient que le **sélecteur de série** (`app_cart_get_cart_latency_seconds_bucket`) et ignore tout le reste : `rate`, `sum by(le)` et `histogram_quantile` n'ont aucun effet sur les marqueurs renvoyés. Vérifié sur le cluster de la formation : les trois écritures rendent les mêmes 31 exemplars, sur les mêmes 4 seaux.

**Survolez un marqueur** : une infobulle donne la valeur, le `trace_id` et un lien. **Cliquez** : Jaeger s'ouvre sur cette requête précise. Au lieu de chercher dans Jaeger une trace qui ressemblerait au symptôme, c'est le symptôme qui vous donne son identifiant.

> ⚠️ **Sur le serveur partagé, l'infobulle propose deux liens.** La démo officielle
> déclare **deux** destinations pour le même exemplar dans sa datasource Prometheus
> (`kubectl get cm grafana-datasources -n otel-demo -o yaml`) : une correcte, résolue
> côté serveur Grafana par son `datasourceUid` ; l'autre porte une URL **en dur**,
> `http://localhost:8080/jaeger/ui/trace/…`. Un artefact du chart amont, pas de ce
> cours — et un cas de plus du piège du Lab 1 : `localhost`, sur ce serveur, c'est
> `student1`. Si vous cliquez ce second lien et n'êtes pas `student1`, Jaeger s'ouvre
> **chez votre voisin**, sur une trace qu'il n'a probablement pas. Prenez le premier
> lien de l'infobulle ; à défaut, copiez le `trace_id` et collez-le dans **votre**
> Jaeger, dans le champ *Lookup by Trace ID...* de la barre du haut.

> 💡 **Côté panel, tout tient dans une case cochée** : *Exemplars*, dans les options de la requête. Elle vaut `"exemplar": true` dans le JSON du panel — allez le vérifier, *Panel → Inspect → Panel JSON*. Décochée, les marqueurs disparaissent sans que la courbe ne bouge.

6.  **La chaîne qui produit un exemplar.** Quatre maillons, du code jusqu'au clic. Le service `cart` les a tous les quatre ; il suffit qu'un seul manque pour qu'il n'y ait rien à cliquer.

**1 — Le SDK attache le `trace_id` à la mesure.** Rien à configurer : quand le SDK du service `cart` enregistre la durée d'un appel, le span de cet appel est encore ouvert dans le contexte. Le SDK y lit le `trace_id` et le range à côté de la valeur mesurée. Il n'en garde pas un par requête, mais **un échantillon par seau de l'histogramme, à chaque cycle d'export** — la spécification OpenTelemetry appelle cela un *exemplar reservoir*, et c'est bien le SDK qui l'applique, pas Prometheus. Sur le cluster de la formation, l'export a lieu toutes les 60 secondes : un quart d'heure de trafic laisse donc au plus 15 exemplars par seau.

**2 — Le transport doit les porter.** Le collecteur reçoit ces mesures en OTLP et les repousse telles quelles vers Prometheus, avec l'exporter `otlphttp/prometheus` :

```bash
kubectl get cm otel-collector-agent -n otel-demo -o jsonpath='{.data.relay}' | grep -A1 'otlphttp/prometheus:'
```

```yaml
  otlphttp/prometheus:
    endpoint: http://prometheus:9090/api/v1/otlp
```

Le protocole OTLP transporte les exemplars nativement : ils voyagent dans le même message que les seaux, sans réglage particulier.

**3 — Prometheus doit les stocker.** Il est démarré avec `--enable-feature=exemplar-storage` ; sans ce drapeau, il les jette à l'ingestion, silencieusement. Et comme le collecteur lui parle en OTLP, il lui faut aussi `--web.enable-otlp-receiver` :

```bash
curl -s "http://$PF_HOST:$PROM_PORT/api/v1/status/flags" | tr ',' '\n' | grep -i 'exemplar\|otlp-receiver'
```

```text
"enable-feature":"exemplar-storage"
"web.enable-otlp-receiver":"true"
```

**4 — Grafana doit savoir où ouvrir la trace.** C'est le `exemplarTraceIdDestinations` de l'étape 3 — l'UID de Jaeger — et, sur le panel, la case *Exemplars*. Le premier dit *où aller*, la seconde dit *va chercher*.

> ⚠️ **Toutes les métriques n'en portent pas.** Les séries `traces_span_metrics_*` n'ont aucun exemplar : le collecteur les recalcule après coup à partir des spans, et le connector `spanmetrics` de la démo est configuré avec `{}` — or cette configuration par défaut n'en produit pas. Rien n'est cassé, il manque une ligne :
>
> ```yaml
> opentelemetry-collector:
>   config:
>     connectors:
>       spanmetrics:
>         exemplars:
>           enabled: true
> ```
>
> Appliquée sur le modèle du Lab 3 — un fichier de values de plus, empilé sur les précédents —, elle rendrait cliquables jusqu'à la trace tous les panels bâtis sur ces métriques. Deux réserves : un exemplar n'est gardé que le temps d'un cycle d'export, et `max_per_data_point` en limite le nombre par point de mesure.

7.  **Le constater sans Grafana.** L'API de Prometheus répond directement :

```bash
. ./scripts/env.sh   # si ce n'est pas déjà fait dans ce terminal

# la métrique du service cart, produite par son SDK
curl -s -G "http://$PF_HOST:$PROM_PORT/api/v1/query_exemplars" \
  --data-urlencode 'query=app_cart_get_cart_latency_seconds_bucket' \
  --data-urlencode "start=$(date -d '-1 hour' +%s)" --data-urlencode "end=$(date +%s)" \
  | head -c 400
echo

# celle que le collecteur recalcule à partir des spans
curl -s -G "http://$PF_HOST:$PROM_PORT/api/v1/query_exemplars" \
  --data-urlencode 'query=traces_span_metrics_duration_milliseconds_bucket' \
  --data-urlencode "start=$(date -d '-1 hour' +%s)" --data-urlencode "end=$(date +%s)"
```

La première réponse est pleine de `trace_id` en clair : le maillon 1 a fait son travail. La seconde tient en une ligne — `{"status":"success","data":[]}` — puisque `spanmetrics` n'en produit aucun.

## À retenir

Un exemplar est le pont entre deux signaux : la **métrique** repère l'incident et le situe dans le temps, l'**exemplar** désigne une requête précise, la **trace** l'explique. C'est le trajet complet que fait un astreinte — et il tient en un clic quand la chaîne est câblée de bout en bout : SDK qui attache le `trace_id`, Prometheus qui le stocke, datasource qui sait où ouvrir la trace.

La lecture détaillée du PromQL de ces panels — les seaux, le p95, la heatmap — est dans le [Lab 4 bonus]({{% relref "42-otel-grafana-bonus" %}}).
