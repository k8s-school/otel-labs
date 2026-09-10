---
title: 'Lab 4 — Dashboard unifié logs / métriques / traces'
date: 2026-07-06T16:55:00+02:00
draft: false
weight: 40
tags: ["Grafana", "dashboard", "Prometheus", "OpenSearch", "Jaeger"]
---

Vous disposez maintenant des trois signaux : traces (Labs 2), métriques système et produit (Lab 3), logs (collectés d'office par la démo). Dans ce lab, vous les rassemblez dans **un seul dashboard Grafana** : la « vue service » que consulterait un astreinte.

Vous en construisez **deux panels** — un de métriques, un de traces — puis vous importez le dashboard de référence, qui apporte les autres.

## Prérequis

* Labs 1 à 3 terminés.
* **D'abord** les variables de la formation chargées dans votre shell : `. ./scripts/env.sh` — elles donnent `$PF_HOST` et `$UI_PORT`, l'adresse et le port de vos UIs.
* **Ensuite** les accès : `./scripts/open-ui.sh`. Le script affiche l'URL de Grafana, `http://$PF_HOST:$UI_PORT/grafana/` — soit `http://localhost:8080/grafana/` sur un poste individuel, mais `http://localhost3:8080/grafana/` pour student3 sur le serveur partagé.

## Étapes

1.  **Explorer les datasources déjà câblées :**

Dans Grafana : ⚙️ *Connections → Data sources*. Trois sources correspondent à nos trois signaux — identifiez-les et notez leur type.

{{%expand "Réponse" %}}
| Datasource | UID | Type | Signal | Backend |
|---|---|---|---|---|
| **Prometheus** | `webstore-metrics` | prometheus | métriques | `http://prometheus:9090` |
| **Jaeger** | `webstore-traces` | jaeger | traces | `http://jaeger:16686/jaeger/ui` |
| **OpenSearch** | `webstore-logs` | grafana-opensearch-datasource | logs | index `otel-logs-*` |

Le chart Helm de la démo les provisionne automatiquement, dans la ConfigMap `grafana-datasources`. Elle contient un fichier de configuration par datasource :

```bash
kubectl describe configmap grafana-datasources -n otel-demo | grep '\.yaml'
```

```text
default.yaml:
jaeger.yaml:
opensearch.yaml:
```

Celui de Prometheus s'appelle `default.yaml` — son nom ne le dit pas, c'est le fichier par défaut du chart. Ouvrez-le :

```bash
kubectl get configmap grafana-datasources -n otel-demo -o jsonpath='{.data.default\.yaml}'
```

Vous y retrouvez l'UID et l'URL du tableau ci-dessus, plus un champ `exemplarTraceIdDestinations` qui relie Prometheus à Jaeger. Il fait l'objet du **Lab 4.2**.

Retenez l'**UID** : c'est par lui qu'un panel désigne sa datasource, et non par son nom d'affichage. Le dashboard de référence, celui du bloc « Solution » plus bas, contient `"datasource": { "type": "prometheus", "uid": "webstore-metrics" }` — c'est ce qui lui permet de s'importer sans re-câbler un seul panel. Un dashboard récupéré ailleurs (grafana.com, un autre cluster) porte d'autres UID : ses panels arrivent vides tant qu'on ne les a pas repointés.
{{% /expand%}}

> 💡 **Où lire l'UID d'une datasource.** En une phrase : l'UID est l'**adresse d'une datasource à l'intérieur de Grafana**. C'est par lui qu'un panel dit « mes données viennent de Prometheus ».
>
> Dans l'interface, ouvrez la datasource : l'UID est **dans l'URL**, en dernier segment — `.../grafana/connections/datasources/edit/webstore-metrics`.
>
> En ligne de commande (la démo autorise l'accès anonyme avec le rôle Admin : aucun jeton à créer) :
>
> ```bash
> . ./scripts/env.sh   # si ce n'est pas déjà fait dans ce terminal
>
> # les UID des trois datasources
> curl -s http://$PF_HOST:$UI_PORT/grafana/api/datasources | grep -o '"uid":"[^"]*"'
> ```
>
> Ces UID servent aussi à relier les datasources **entre elles** — c'est ce qui permettra, au Lab 4.2, de passer d'un point de métrique à la trace correspondante.

2.  **Créer un dashboard vide** (*Dashboards → New → New dashboard*), puis **ajouter la variable `service_name`** :

*Settings → Variables → New variable* :
* *Select variable type* : `Query`
* *Data source* : **Prometheus**
* *Query type* : **Classic query**
* *Classic query* : `label_values(traces_span_metrics_calls_total, service_name)`

> 💡 **Ce que fait cette ligne.** Une **variable** ajoute un menu déroulant en haut du dashboard. Partout où un panel écrira `$service_name`, Grafana remplacera par la valeur choisie avant d'interroger Prometheus : sélectionnez `checkout`, et `service_name=~"$service_name"` part en `service_name=~"checkout"`. Un seul dashboard suffit donc pour les quinze services de la boutique, au lieu d'un par service.
>
> `label_values(...)` n'est pas du PromQL : c'est une fonction de Grafana, réservée aux variables de type *Query*. Elle se lit « donne-moi toutes les valeurs du label `service_name` présentes sur la métrique `traces_span_metrics_calls_total` ». Le menu se remplit donc tout seul — rien n'est écrit en dur — et suit les services qui apparaissent ou disparaissent.
>
> Reste le choix de la métrique. `traces_span_metrics_calls_total` est produite par le connector **spanmetrics** du collecteur (vu au Lab 3), qui compte les spans qu'il voit passer : elle est donc dérivée **des traces**. Le menu liste ainsi exactement les services qui tracent. Son intérêt : elle porte le **même nom et les mêmes labels pour tous les services**, quel que soit leur langage — un seul dashboard les couvre tous. Les métriques que les applications exportent elles-mêmes n'ont pas cette uniformité : votre `review-service` publie par exemple `http_server_request_duration_seconds` et une trentaine de `jvm_*`, que les services Go ou Python de la boutique ne connaissent pas.

3.  **Panel 1 — métriques (Prometheus) :** un *Time series* « Débit de spans » :

```promql
sum(rate(traces_span_metrics_calls_total{service_name=~"$service_name"}[2m]))
```

> 💡 **Cette requête, mot à mot.** Elle se lit de l'intérieur vers l'extérieur, et chacun des trois morceaux répond à une question différente.
>
> * **`traces_span_metrics_calls_total{service_name=~"$service_name"}`** — *quoi ?* Un **compteur** produit par spanmetrics : le nombre de spans vus depuis le démarrage du collecteur. Le suffixe `_total` est la convention Prometheus pour un compteur, une valeur qui ne fait que monter. Entre accolades, le filtre : seulement le service choisi dans le menu.
> * **`rate(...[2m])`** — *à quelle vitesse ?* Un compteur brut ne se lit pas : « 48 219 spans depuis le démarrage » n'apprend rien. `rate` en prend la pente sur les **2 dernières minutes** et rend des **spans par seconde**. C'est cela qu'on veut voir monter et descendre.
> * **`sum(...)`** — *combien en tout ?* spanmetrics ne tient pas un compteur par service, mais un par **opération** (`span_name`) et par statut. Sans `sum`, le panel afficherait des dizaines de courbes ; `sum` les écrase en une seule, le débit total du service.
>
> **L'ordre compte : toujours `rate` d'abord, `sum` ensuite.** `rate` sait reconnaître qu'un compteur est reparti de zéro — un pod du collecteur qui redémarre — et corriger ; mais il ne le peut que série par série. Additionnez avant, et la baisse se lit comme une remise à zéro du total : le panel affiche alors un **pic de trafic au moment précis où un pod est mort**. La démonstration chiffrée est dans le [Lab 4.1]({{% relref "41-otel-histogramme" %}}).

4.  **Panel 2 — traces (Jaeger) :** datasource **Jaeger**, query type *Search*, service `$service_name`, limit 20.

> ⚠️ **Le panel restera vide tant que vous n'aurez pas coché *Table view***, l'interrupteur en haut de l'éditeur de panel. La visualisation par défaut est un graphe temporel : elle ne sait pas représenter une liste de traces, et n'affiche donc **rien du tout — sans message d'erreur**, ce qui laisse croire que la requête est en cause. Elle ne l'est pas : la requête ci-dessus est correcte. (Vous pouvez aussi choisir la visualisation *Table* dans le sélecteur en haut à droite ; *Table view* est simplement plus rapide.)

{{%expand "Solution" %}}
**Importer le dashboard de référence** — il arrive **à côté du vôtre**, sans l'écraser : son `uid` (`otel-training-service`) n'est pas celui de votre création.

```bash
. ./scripts/env.sh   # si ce n'est pas déjà fait dans ce terminal

curl -sS -X POST http://$PF_HOST:$UI_PORT/grafana/api/dashboards/db \
  -H "Content-Type: application/json" \
  -d "{\"overwrite\": true, \"dashboard\": $(cat content/1_Labs/40-otel-grafana-dashboard.json)}"

# l'URL du dashboard importé, à ouvrir directement
echo "http://$PF_HOST:$UI_PORT/grafana/d/otel-training-service"
```

Il s'intitule **« Vue service — Formation OTel »** et arrive à la racine, sans dossier : dans *Dashboards*, il se retrouve mêlé aux huit dashboards livrés par la démo. Plutôt que de le chercher, ouvrez l'URL ci-dessus — c'est l'`uid` du dashboard, pas son titre, qui la détermine.

Il contient **quatre panels** : vos deux (débit, traces), plus les deux que vous n'avez pas écrits — la **latence p95** et les **logs** du service, en Lucene sur OpenSearch (`resource.service.name:"$service_name"`). Les quatre sont pilotés par la même variable : c'est l'objectif du lab, les trois signaux d'un même service sur un écran.
{{% /expand%}}

> 💡 **Panels vides sur `review-service` ?** C'est normal, et instructif : les services de la boutique reçoivent du trafic en permanence — le load generator s'en charge — mais **le vôtre n'en reçoit que si vous lui en envoyez**. Ses derniers logs peuvent dater de votre session précédente. Réveillez-le :
>
> ```bash
> . ./scripts/env.sh   # si ce n'est pas déjà fait dans ce terminal
> for i in $(seq 1 10); do curl -s -o /dev/null http://$PF_HOST:$APP_PORT/api/reviews; done
> ```
>
> (ou postez quelques avis depuis sa page web, `http://$PF_HOST:$APP_PORT/`). Une vingtaine de secondes plus tard, les logs `Listing all reviews` remplissent le panel — et les panels Prometheus se garnissent de la même façon, sans requêtes il n'y a ni débit ni latence à tracer.
>
> Si le panel reste vide malgré le trafic, vérifiez qu'une **instrumentation** tourne : c'est elle qui transforme les logs de l'application en LogRecords envoyés au collecteur. Deux le font, et **toutes deux capturent les logs** — l'agent Java du Lab 2 (partie 1) comme le Spring Boot Starter (partie 2, celui que vous avez déployé en dernier).
>
> ```bash
> # l'agent Java est-il actif ?
> kubectl set env deploy/review-service -n otel-demo --list | grep JAVA_TOOL_OPTIONS
>
> # sinon, l'image embarque-t-elle le starter ? (tag « starter-… »)
> kubectl get deploy review-service -n otel-demo \
>   -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
> ```
>
> Ni l'un ni l'autre — une image `default-…` sans `JAVA_TOOL_OPTIONS` — et l'application n'émet **rien du tout** : ni logs, ni traces, ni métriques. C'est l'état du tout début du Lab 2, celui où Jaeger restait désespérément vide.

5.  **Faire vivre le dashboard.** Basculez la variable `service_name` entre `frontend`, `checkout` et `review-service` : les quatre panels suivent. C'est l'objectif du lab — les trois signaux d'un même service sur un seul écran.

Le quatrième panel, **« Latence p95 (ms) »**, arrive avec l'import : vous ne l'avez pas écrit.

```promql
topk(5, histogram_quantile(0.95, sum(rate(traces_span_metrics_duration_milliseconds_bucket{
  service_name=~"$service_name", span_name=~"$span_name"}[2m])) by (le, span_name)))
```

> 💡 **Le p95 en une phrase** : 95 % des requêtes ont été **plus rapides** que la valeur affichée ; une sur vingt a été plus lente. On le préfère à la moyenne parce qu'une moyenne noie les lentes — sur 100 requêtes dont 90 à 4 ms et 10 à 500 ms, elle annonce 54 ms, une durée que personne n'a connue. Le p95, lui, affiche 500 ms : ce que vit un utilisateur sur dix.

**Et il ne coûte rien à produire.** La métrique interrogée, `traces_span_metrics_duration_milliseconds_bucket`, sort du même connector **spanmetrics** que le compteur du panel 1 : le collecteur chronomètre déjà chaque span qu'il voit passer. Personne n'a ajouté de timer dans le `review-service`, ni bibliothèque, ni ligne de code — tracer suffit. Et comme le nom et les labels sont les mêmes partout, ce panel unique donne la latence des quinze services de la boutique, quel que soit leur langage.

Ce qu'on lui demande, ici, c'est de répondre d'un coup d'œil à « ça va, ou pas ? ». Le trait rouge à 20 ms est un repère de lecture calibré sur le `review-service`, qui tourne autour de 4 ms au repos : au-delà, quelque chose a changé. Il arrive aussi avec une **seconde variable**, `span_name` : chaque opération du service y est listée, et le `by (le, span_name)` de la requête calcule un p95 **par opération** plutôt qu'un chiffre unique pour tout le service. Le `topk(5)` garde les cinq plus lentes à l'écran — de quoi voir tout de suite *laquelle* traîne, là où un seul chiffre agrégé ne dirait rien. Ce que ces cinq ou six spans par requête deviennent une fois chronométrés par spanmetrics, et pourquoi un p95 calculé sur tous ne mesure pas la latence des requêtes, sont le sujet du [Lab 4 bonus]({{% relref "43-otel-spanmetrics" %}}).

6.  **Exporter votre dashboard en JSON.** Ce n'est pas dans le menu *Share*, qui ne propose que *Share internally* / *Share externally*. L'export est l'**icône ⤓ de la barre verticale, à droite du dashboard** (infobulle *Export*) : cliquez-la, puis *Export as code*. Le panneau *Export dashboard* affiche le JSON ; le bouton **Download file** l'enregistre.

    C'est le **livrable**, à committer dans votre dépôt — même s'il ne contient que la variable et vos deux panels.

## Pour aller plus loin

* [**Lab 4.1 — Lire un panel de latence : heatmap, p95 et faux pics**]({{% relref "41-otel-histogramme" %}}) — le PromQL des seaux, comment une heatmap se construit, et pourquoi le p95 n'en est que le résumé. La théorie derrière le panel « Latence p95 ».
* [**Lab 4.2 — Exemplars : du point de métrique à la trace**]({{% relref "42-otel-exemplars" %}}) — le chaînon qui manque entre le p95 et Jaeger, sur un dashboard livré par la démo. Rien à construire, tout à lire.
* [**Lab 4 bonus — spanmetrics : une requête n'est pas un span**]({{% relref "43-otel-spanmetrics" %}}) — le trio RED pour tous les services, et pourquoi un p95 calculé sur tous les spans d'un service ne mesure pas la latence de ses requêtes.

## Livrable

Votre dashboard « vue service » exporté en JSON, avec sa variable `service_name` et au moins un panel qu'elle pilote. Le dashboard de référence importé au bloc « Solution » montre la cible complète — les trois signaux d'un même service côte à côte.
