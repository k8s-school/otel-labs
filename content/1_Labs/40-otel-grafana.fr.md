---
title: 'Lab 4 — Dashboard unifié logs / métriques / traces'
date: 2026-07-06T16:55:00+02:00
draft: false
weight: 40
tags: ["Grafana", "dashboard", "Prometheus", "OpenSearch", "Jaeger"]
---

Vous disposez maintenant des trois signaux : traces (Labs 2), métriques système et produit (Lab 3), logs (collectés d'office par la démo). Dans ce lab, vous les rassemblez dans **un seul dashboard Grafana** : la « vue service » que consulterait un astreinte.

Vous en construisez **deux panels** — un de métriques, un de traces — puis vous importez le dashboard de référence, qui apporte les autres. Vous terminez par une règle d'alerte sur la latence.

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
| **Jaeger** | `webstore-traces` | jaeger | traces | `http://jaeger:16686` |
| **OpenSearch** | `webstore-logs` | grafana-opensearch-datasource | logs | index `otel-logs-*` |

Le chart Helm de la démo les provisionne automatiquement (ConfigMap `grafana-datasources`). Ouvrez la configuration de Prometheus : elle contient un bloc `exemplars` qui la relie à Jaeger — c'est le sujet du **Lab 4.1**.

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
> Ces UID servent aussi à relier les datasources **entre elles** — c'est ce qui permettra, au Lab 4.1, de passer d'un point de métrique à la trace correspondante.

2.  **Créer un dashboard vide** (*Dashboards → New → New dashboard*), puis **ajouter la variable `service_name`** :

*Settings → Variables → New variable* :
* Type `Query`, datasource **Prometheus**
* Query : `label_values(traces_span_metrics_calls_total, service_name)`

> 💡 **Ce que fait cette ligne.** Une **variable** ajoute un menu déroulant en haut du dashboard. Partout où un panel écrira `$service_name`, Grafana remplacera par la valeur choisie avant d'interroger Prometheus : sélectionnez `checkout`, et `service_name=~"$service_name"` part en `service_name=~"checkout"`. Un seul dashboard suffit donc pour les quinze services de la boutique, au lieu d'un par service.
>
> `label_values(...)` n'est pas du PromQL : c'est une fonction de Grafana, réservée aux variables de type *Query*. Elle se lit « donne-moi toutes les valeurs du label `service_name` présentes sur la métrique `traces_span_metrics_calls_total` ». Le menu se remplit donc tout seul — rien n'est écrit en dur — et suit les services qui apparaissent ou disparaissent.
>
> Reste le choix de la métrique. `traces_span_metrics_calls_total` est produite par le connector **spanmetrics** du collecteur (vu au Lab 3), qui compte les spans qu'il voit passer : elle est donc dérivée **des traces**. Le menu liste ainsi exactement les services qui tracent — y compris `review-service`, qui hérite au passage de métriques de débit et de latence sans avoir été instrumenté pour les métriques !

3.  **Panel 1 — métriques (Prometheus) :** un *Time series* « Débit de requêtes » :

```promql
sum(rate(traces_span_metrics_calls_total{service_name=~"$service_name"}[2m]))
```

> 💡 **Cette requête, mot à mot.** Elle se lit de l'intérieur vers l'extérieur, et chacun des trois morceaux répond à une question différente.
>
> * **`traces_span_metrics_calls_total{service_name=~"$service_name"}`** — *quoi ?* Un **compteur** produit par spanmetrics : le nombre de spans vus depuis le démarrage du collecteur. Le suffixe `_total` est la convention Prometheus pour un compteur, une valeur qui ne fait que monter. Entre accolades, le filtre : seulement le service choisi dans le menu.
> * **`rate(...[2m])`** — *à quelle vitesse ?* Un compteur brut ne se lit pas : « 48 219 spans depuis le démarrage » n'apprend rien. `rate` en prend la pente sur les **2 dernières minutes** et rend des **spans par seconde**. C'est cela qu'on veut voir monter et descendre.
> * **`sum(...)`** — *combien en tout ?* spanmetrics ne tient pas un compteur par service, mais un par **opération** (`span_name`), sens d'appel (`span_kind`) et statut. Sans `sum`, le panel afficherait des dizaines de courbes ; `sum` les écrase en une seule, le débit total du service.
>
> **L'ordre compte : toujours `rate` d'abord, `sum` ensuite.** `rate` sait reconnaître qu'un compteur est reparti de zéro — un pod du collecteur qui redémarre — et corriger ; mais il ne le peut que série par série. Additionnez avant, et la baisse se lit comme une remise à zéro du total : le panel affiche alors un **pic de trafic au moment précis où un pod est mort**. La démonstration chiffrée est dans le [Lab 4 bonus]({{% relref "42-otel-grafana-bonus" %}}).

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

Il s'intitule **« Vue service — Formation OTel »** et arrive à la racine, sans dossier : dans *Dashboards*, il se retrouve mêlé aux neuf dashboards livrés par la démo. Plutôt que de le chercher, ouvrez l'URL ci-dessus — c'est l'`uid` du dashboard, pas son titre, qui la détermine.

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

5.  **Lire le panel « Latence p95 »** du dashboard importé, et basculez la variable `service_name` entre `frontend`, `checkout` et `review-service` : les quatre panels suivent.

```promql
histogram_quantile(0.95, sum(rate(traces_span_metrics_duration_milliseconds_bucket{service_name=~"$service_name"}[2m])) by (le))
```

Il se lit en une phrase : *sur les deux dernières minutes, 95 % des spans de ce service ont été plus rapides que la valeur affichée.*

**À quoi sert-il ?** À répondre « ça va, ou pas ? » — pas à expliquer pourquoi. Une métrique coûte trois fois rien et se garde des mois : elle dit **qu'il y a** un problème et depuis quand. Une trace, elle, dit **laquelle** des requêtes a souffert, mais elle est volumineuse et ne vit que quelques jours. D'où le p95 en vitrine et les traces juste derrière : le panel repère l'incident, le panel *Traces récentes* — et surtout les **exemplars** du Lab 4.1 — mènent à la requête fautive.

Pourquoi un percentile plutôt qu'une moyenne ? Parce qu'une moyenne noie les cas lents : dix requêtes à 10 ms et une à 2 s font une moyenne de 190 ms, qui ne décrit aucune des onze. Le p95 dit ce que vivent les 5 % les moins bien servis.

> 💡 Le détail de cette requête — ce qu'est un seau `le`, pourquoi un percentile ne s'additionne pas, et ce que ce p95 ne dit pas — est dans le [Lab 4 bonus]({{% relref "42-otel-grafana-bonus" %}}).

6.  **Installer la règle d'alerte.** Le panel trace le p95 avec son **seuil à 20 ms en rouge** ; la règle qui surveille ce seuil s'installe en deux commandes — un dossier pour la ranger, puis la règle elle-même :

```bash
. ./scripts/env.sh   # si ce n'est pas déjà fait dans ce terminal
GRAFANA="http://$PF_HOST:$UI_PORT/grafana"

# 1. le dossier qui accueillera la règle
curl -sS -X POST "$GRAFANA/api/folders" -H "Content-Type: application/json" \
  -d '{"uid":"otel-training","title":"Formation OTel"}'

# 2. la règle : p95 du review-service > 20 ms pendant 1 minute
curl -sS -X POST "$GRAFANA/api/v1/provisioning/alert-rules" \
  -H "Content-Type: application/json" -H "X-Disable-Provenance: true" \
  -d @content/1_Labs/40-otel-grafana-alert.json

echo "$GRAFANA/alerting/list"
```

Ouvrez l'URL affichée : la règle **« Latence p95 du review-service »** y est, à l'état `Normal`. (Si vous rejouez ces commandes, Grafana répondra que le dossier existe déjà — sans conséquence.)

> 💡 **Pourquoi deux commandes, et pas une ligne de plus dans le dashboard ?** Parce qu'une règle d'alerte **ne vit pas dans le dashboard**. Jusqu'à Grafana 10 elle était rangée dans le JSON du panel ; l'alerting unifié l'en a sortie (l'ancien système a disparu en Grafana 11, et la démo tourne en 13). Une règle est désormais un objet à part, avec son API, et Grafana exige de la ranger dans un **dossier** et dans un **groupe d'évaluation** — ici le groupe `formation-otel`, évalué toutes les 60 secondes. Elle reste toutefois **rattachée au panel** : le JSON contient l'`uid` du dashboard et l'id du panel, c'est ce qui permet de passer de l'un à l'autre d'un clic.
>
> Le `X-Disable-Provenance: true` mérite un mot : sans lui, Grafana marque la règle « provisionnée » et l'interface **interdit de la modifier**. Avec lui, vous pourrez ouvrir la règle et changer le seuil à la souris.
>
> Notez enfin le service, écrit **en dur** dans la requête : `service_name="review-service"`. Une règle d'alerte n'a pas de menu déroulant — la variable `$service_name` du dashboard n'existe pas pour elle. Si vous créez une règle depuis un panel (*Panel → More → New alert rule*), Grafana y fige la valeur affichée au moment du clic, sans le dire.

7.  **La faire sonner.** Votre `review-service` n'a de trafic que celui que vous lui envoyez, et il est rapide : au repos, son p95 tourne autour de **4 ms**. D'où le seuil à 20 ms — cinq fois le repos. Un seuil ne se choisit pas dans l'absolu, il se calibre sur le service qu'il surveille.

Pour le faire monter, ce n'est pas le **nombre** de requêtes qui compte, c'est le nombre de requêtes **en même temps** : trente clients en parallèle pendant trois minutes.

```bash
. ./scripts/env.sh   # si ce n'est pas déjà fait dans ce terminal
for i in $(seq 1 30); do
  ( fin=$((SECONDS+180))
    while [ $SECONDS -lt $fin ]; do
      curl -s -o /dev/null --max-time 10 http://$PF_HOST:$APP_PORT/api/reviews
    done ) &
done
wait
```

Pendant que ça tourne, remettez la variable `service_name` sur **`review-service`** et regardez **le panel** « Latence p95 » : la courbe décolle et franchit la ligne rouge — mesuré en salle, ~40 ms, soit le double du seuil. Puis la page *Alerting → Alert rules*, où la règle change d'état :

* `Normal` — le p95 est sous le seuil ;
* `Pending` — il vient de passer au-dessus, mais la règle attend que le dépassement **dure** (son `for`, 1 minute) ;
* `Firing` — le dépassement a duré : l'alerte est déclarée.

Chronologie relevée en salle : `Pending` au bout d'une **trentaine de secondes** — la première évaluation qui voit le dépassement —, puis `Firing` à **1 min 40**, à l'évaluation suivante, une fois le `for` écoulé. Le groupe s'évalue toutes les 60 secondes : il faut donc deux évaluations au-dessus du seuil.

Ces trois éléments — la **condition** (la ligne rouge), la **durée** (`for`), les **états** — sont tout ce qui fait une alerte. Le `for` est ce qui sépare un pic isolé d'un incident : sans lui, la moindre requête lente réveillerait quelqu'un.

{{%expand "Pourquoi ces trente clients, et pas un million de requêtes ?" %}}
Parce qu'un million de `curl` lancés **les uns après les autres** ne chargent rien : le service ne voit jamais qu'une requête à la fois, la traite en 4 ms, et recommence. Le p95 ne bouge pas — il faudrait juste beaucoup de patience.

Ce qui fait monter une latence, c'est la **concurrence** : les requêtes qui attendent leur tour derrière les autres. Mesuré sur le cluster de la formation :

| Requêtes simultanées | p95 |
|---|---|
| 1 (séquentiel) | 4 ms |
| 30 | 41 ms |
| 60 | 50 ms |
| 120 | 175 ms |

Deuxième piège : **la cible compte autant que la charge**. La page d'accueil du service (`http://$PF_HOST:$APP_PORT/`) est un fichier statique, servi en 1 ms sans toucher la base. La marteler *ferait baisser* le p95 : le panel agrège toutes les opérations du service, et des milliers de spans très rapides tirent la distribution vers le bas. C'est `GET /api/reviews`, avec son `SELECT`, qui souffre de la concurrence.

Enfin, évitez de charger en **POST** : chaque appel insère un avis, et comme `GET /api/reviews` liste toute la table, quelques minutes de POST laissent le service durablement plus lent — le seuil ne veut alors plus dire la même chose.
{{% /expand%}}

> 💡 **Deux choses qui surprennent.** D'abord, **rien n'arrive dans aucune boîte** : la démo ne configure aucun point de contact, l'alerte se lit donc dans l'interface et nulle part ailleurs. Ensuite, quand vous arrêtez la charge, le retour à `Normal` prend encore **deux bonnes minutes** : la requête moyenne les latences sur une fenêtre de deux minutes (`rate(...[2m])`), et cette fenêtre doit d'abord se vider des requêtes lentes.

> 💡 **En production, cette alerte ne vivrait probablement pas dans Grafana.** On l'écrirait côté **Prometheus**, en YAML versionné dans Git :
>
> ```yaml
> groups:
>   - name: service-slo
>     rules:
>       - alert: HighLatencyP95
>         expr: histogram_quantile(0.95, sum(rate(traces_span_metrics_duration_milliseconds_bucket[2m])) by (le, service_name)) > 20
>         for: 1m
>         labels:
>           severity: warning
>         annotations:
>           summary: "p95 > 20 ms sur {{ $labels.service_name }}"
> ```
>
> Vous y retrouvez exactement les trois éléments observés : `expr` est la condition, `for` la durée, et les états `Pending` → `Firing` sont les mêmes. Seul l'endroit change — et cela change trois choses : la règle est **revue en PR comme du code**, elle est **évaluée par Prometheus même si Grafana est éteint**, et **Alertmanager** prend en charge ce que Grafana ne fait qu'en partie : déduplication, groupement, silences pendant une maintenance, routage vers Slack ou PagerDuty.
>
> L'alerting Grafana garde un avantage que Prometheus ne peut pas avoir : il est **multi-datasources**. Une règle Grafana peut croiser une métrique Prometheus et des logs OpenSearch dans la même condition ; une règle Prometheus ne voit que du PromQL.
>
> Pourquoi ce lab ne la déploie pas de ce côté-là : la démo désactive `alertmanager` (aucune notification à recevoir) **et** `configmapReload` (Prometheus ne relit pas sa configuration à chaud). Il faudrait un `helm upgrade` **et** un redémarrage de Prometheus pour voir passer trois lignes de YAML.

8.  **Exporter votre dashboard en JSON** (*Share → Export → Save to file*) : c'est le **livrable**, à committer dans votre dépôt — même s'il ne contient que la variable et vos deux panels.

## Pour aller plus loin

* [**Lab 4.1 — Exemplars : du point de métrique à la trace**]({{% relref "41-otel-exemplars" %}}) — le chaînon qui manque entre le p95 et Jaeger, sur un dashboard livré par la démo. Rien à construire, tout à lire.
* [**Lab 4 bonus — Lire un histogramme : p95 et heatmap**]({{% relref "42-otel-grafana-bonus" %}}) — le PromQL des seaux, ce que le p95 cache, et pourquoi une heatmap en dit parfois davantage.

## Livrable

Votre dashboard « vue service » exporté en JSON, avec sa variable `service_name` et au moins un panel qu'elle pilote — et la règle d'alerte vue passer en `Firing`. Le dashboard de référence importé au bloc « Solution » montre la cible complète — les trois signaux d'un même service côte à côte.
