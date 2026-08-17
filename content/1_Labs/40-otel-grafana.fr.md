---
title: 'Lab 4 — Dashboard unifié logs / métriques / traces'
date: 2026-07-06T16:55:00+02:00
draft: false
weight: 40
tags: ["Grafana", "dashboard", "Prometheus", "OpenSearch", "Jaeger"]
---

Vous disposez maintenant des trois signaux : traces (Labs 2), métriques système et produit (Lab 3), logs (collectés d'office par la démo). Dans ce lab, vous les rassemblez dans **un seul dashboard Grafana** : la « vue service » que consulterait un astreinte.

## Prérequis

* Labs 1 à 3 terminés.
* **D'abord** les variables de la formation chargées dans votre shell : `. ./scripts/env.sh` — elles donnent `$PF_HOST` et `$UI_PORT`, l'adresse et le port de vos UIs.
* **Ensuite** le port-forward des UIs : `./scripts/open-ui.sh`. Le script affiche l'URL de Grafana, `http://$PF_HOST:$UI_PORT/grafana/` — soit `http://localhost:8080/grafana/` sur un poste individuel, mais `http://localhost3:8080/grafana/` pour student3 sur le serveur partagé.

## Étapes

1.  **Explorer les datasources déjà câblées :**

Dans Grafana : ⚙️ *Connections → Data sources*. Trois sources correspondent à nos trois signaux — identifiez-les et notez leur type.

{{%expand "Réponse" %}}
| Datasource | UID | Type | Signal | Backend |
|---|---|---|---|---|
| **Prometheus** | `webstore-metrics` | prometheus | métriques | `http://prometheus:9090` |
| **Jaeger** | `webstore-traces` | jaeger | traces | `http://jaeger:16686` |
| **OpenSearch** | `webstore-logs` | grafana-opensearch-datasource | logs | index `otel-logs-*` |

Le chart Helm de la démo les provisionne automatiquement (ConfigMap `grafana-datasources`). Ouvrez la configuration de Prometheus : elle contient un bloc `exemplars` qui la relie à Jaeger — c'est le sujet de l'étape 10.

Retenez l'**UID** : c'est par lui qu'un panel désigne sa datasource, et non par son nom d'affichage. Le dashboard de référence de l'étape 5 contient `"datasource": { "type": "prometheus", "uid": "webstore-metrics" }` — c'est ce qui lui permet de s'importer sans re-câbler un seul panel. Un dashboard récupéré ailleurs (grafana.com, un autre cluster) porte d'autres UID : ses panels arrivent vides tant qu'on ne les a pas repointés.
{{% /expand%}}

> 💡 **Avancé — où lire l'UID d'une datasource, et à quoi il sert.**
>
> En une phrase : l'UID est l'**adresse d'une datasource à l'intérieur de Grafana**. C'est par lui qu'un panel dit « mes données viennent de Prometheus » — et c'est par lui aussi que Prometheus dit « mes traces, elles, se lisent dans Jaeger ». Sans UID, ces briques ne sauraient pas se désigner entre elles.
>
> Deux chemins pour le lire, l'un pour la souris, l'autre pour un script.
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
>
> # celui d'une datasource précise, par son nom d'affichage
> curl -s http://$PF_HOST:$UI_PORT/grafana/api/datasources/name/Prometheus | grep -o '"uid":"[^"]*"'
> ```
>
> Cette même API montre le **lien Prometheus → Jaeger** écrit avec un UID. La configuration d'une datasource se lit dans le champ `jsonData` de la réponse ; isolons-en une ligne, celle de Prometheus :
>
> ```bash
> curl -s http://$PF_HOST:$UI_PORT/grafana/api/datasources/name/Prometheus \
>   | grep -o '"exemplarTraceIdDestinations":\[[^]]*\]'
> ```
>
> ```json
> "exemplarTraceIdDestinations":[{"datasourceUid":"webstore-traces","name":"trace_id"}, ...]
> ```
>
> Traduction : « quand tu rencontres un `trace_id` dans une métrique, va ouvrir la trace dans la datasource dont l'UID est `webstore-traces` » — c'est-à-dire Jaeger. Concrètement, c'est cette ligne qui permet de passer **d'un point sur une courbe Prometheus à la trace correspondante dans Jaeger**, en un clic. Sans elle, Grafana saurait qu'il tient un identifiant de trace, mais pas où aller la chercher. C'est le mécanisme des **exemplars**, à l'étape 10.
>
> La même configuration se lit à deux autres endroits : dans l'interface, sur la page de la datasource Prometheus ; et à la source, dans la ConfigMap qui la provisionne — `kubectl get configmap grafana-datasources -n otel-demo -o yaml`.

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

Ajoutez un second panel « Latence p95 » :

```promql
histogram_quantile(0.95, sum(rate(traces_span_metrics_duration_milliseconds_bucket{service_name=~"$service_name"}[2m])) by (le))
```

> 💡 **Pourquoi ce `sum` ?** Parce que spanmetrics ne tient pas un compteur par service, mais un par **opération** (`span_name`), sens d'appel (`span_kind`) et statut : sans `sum`, le panel afficherait des dizaines de courbes. `sum` les écrase en une seule — le débit total du service, en requêtes par seconde.
>
> Et l'ordre compte : toujours **`rate` d'abord, `sum` ensuite**. `rate` sait reconnaître qu'un compteur est reparti de zéro (redémarrage d'un pod du collecteur) et corriger ; il ne le peut que série par série. Additionnez avant, et la baisse se lit comme un reset du total : le panel affiche un **pic de trafic au moment précis où un pod est mort**. Le second panel suit exactement le même ordre, pour la même raison.

{{%expand "Avancé — le pic fantôme, en chiffres (PromQL, hors programme)" %}}
Deux pods de collecteur, `A` et `B`, 2 requêtes/s chacun — donc **4 req/s en réalité**, stable. Scrape toutes les 15 s. `B` redémarre à t=45 s.

| t | A | rate(A) | B | rate(B) | **sum(rate)** ✅ | A+B | **rate(sum)** ❌ |
|---|---|---|---|---|---|---|---|
| 0 s | 1000 | — | 800 | — | — | 1800 | — |
| 15 s | 1030 | 2/s | 830 | 2/s | **4/s** | 1860 | **4/s** |
| 30 s | 1060 | 2/s | 860 | 2/s | **4/s** | 1920 | **4/s** |
| 45 s | 1090 | 2/s | **0** ⚡ | 0/s | **2/s** | **1090** | **≈ 73/s** 💥 |
| 60 s | 1120 | 2/s | 30 | 2/s | **4/s** | 1150 | **4/s** |

Les deux écritures donnent le même résultat partout, **sauf sur la ligne du redémarrage**.

À gauche, `rate` compare 0 à 860 sur la seule série de `B` : reset reconnu, delta ramené à 0 — le pod n'a effectivement rien compté pendant qu'il redémarrait. La courbe creuse à 2/s, ce qui est la vérité : la moitié de la capacité était absente.

À droite, la même comparaison se fait sur le total, 1090 contre 1920. Baisse, donc reset, donc delta = 1090 → `1090 / 15 ≈ 73/s`. Ce 1090, ce sont les **requêtes cumulées de `A` depuis son propre démarrage**, comptées d'un coup comme si elles venaient d'arriver en 15 secondes. Le pic n'est pas du trafic : c'est l'historique de `A` relâché sur un intervalle. Et plus `A` tourne depuis longtemps, pire c'est — à 50 000 au compteur, le faux pic monterait à 3 300/s.

Deux détails que le tableau simplifie : un vrai `rate[2m]` étale ce pic sur la fenêtre au lieu de le concentrer sur un point (plus bas, plus large, même erreur totale) ; et PromQL rend d'ailleurs la mauvaise écriture malaisée — `rate(sum(...)[2m])` est invalide, il faut une *subquery* pour y arriver.
{{% /expand%}}

> 💡 **Et le panel latence : `_bucket`, `le`, et pourquoi un p95 se recalcule.** spanmetrics ne conserve pas la durée de chaque span — ce serait revenir aux traces. Il les **range dans des seaux** : `..._duration_milliseconds_bucket{le="100"}` compte les spans qui ont duré **100 ms ou moins** (`le` = *less or equal*). Ces seaux sont **cumulatifs** — un span de 30 ms incrémente aussi celui des 100 ms, celui des 500 ms, et ainsi de suite jusqu'à `le="+Inf"` qui les contient tous.
>
> ```text
> ..._bucket{le="10"}    = 120     ← 120 spans ont duré 10 ms ou moins
> ..._bucket{le="50"}    = 380       (les 120 précédents sont dedans)
> ..._bucket{le="100"}   = 450
> ..._bucket{le="500"}   = 495
> ..._bucket{le="+Inf"}  = 500     ← tous les spans
> ```
>
> Ces cinq lignes se lisent : 500 spans observés, dont 450 sous 100 ms et 495 sous 500 ms. Or le p95, c'est la durée du **475e span** (95 % de 500) une fois triés du plus rapide au plus lent. Il tombe donc entre le 450e et le 495e, c'est-à-dire **entre 100 et 500 ms**. Sa valeur exacte, en revanche, n'est nulle part dans `traces_span_metrics_duration_milliseconds_bucket` : cette métrique ne retient que des **comptages par seau**, jamais les durées individuelles. Il faudra donc la **reconstituer**.
>
> *« Et pourquoi ne pas aller lire la durée du 475e span dans Jaeger, tout simplement ? »* Parce qu'il n'y est peut-être pas — au Lab 7, le tail sampling ne gardera qu'un quart des traces — et parce qu'un service réel produit des millions de spans par minute : les trier à chaque rafraîchissement du panel, sur six heures de fenêtre, n'est pas tenable. Les traces vivent d'ailleurs quelques jours, les métriques des mois. Chaque signal fait donc son métier : la métrique dit **qu'il y a** un problème et depuis quand, pour trois fois rien et sur la longue durée ; la trace dit **laquelle** des requêtes a souffert. L'étape 10 montrera comment passer de l'une à l'autre.
>
> Ce détour a une raison précise : **un percentile ne s'additionne pas**. La moyenne du p95 de deux pods n'est pas le p95 de l'ensemble, c'est un nombre sans signification. Des seaux, eux, s'additionnent sans difficulté : 120 spans sous 10 ms ici, 200 là, cela fait bien 320. On renonce donc aux durées exactes pour gagner le droit d'agréger, quitte à recalculer le percentile au moment de l'affichage.
>
> D'où la requête, lue de l'intérieur vers l'extérieur :
>
> * `rate(...[2m])` — chaque seau est un compteur cumulé **depuis le démarrage du collecteur**. Sans `rate`, le panel décrirait la distribution des latences *depuis toujours*, une courbe presque immobile où l'incident d'il y a trois heures pèse autant que la minute en cours ;
> * `sum(...) by (le)` — réunit toutes les opérations et toutes les instances **en gardant le découpage par seau**. Un `sum` nu écraserait aussi `le` : il ne resterait plus de distribution à lire, et la fonction suivante renverrait `NaN` ;
> * `histogram_quantile(0.95, ...)` — relit cette distribution et rend le seuil sous lequel tombent 95 % des spans, **en millisecondes** (le nom de la métrique le dit ; les métriques des SDK, elles, sont souvent en `_seconds`).
>
> En une phrase : *sur les deux dernières minutes, 95 % des spans de ce service ont été plus rapides que la valeur affichée.*

{{%expand "Avancé — ce que ce p95 ne dit pas (hors programme)" %}}
**Sa précision est celle des seaux.** Reprenons le 475e span. Il se trouve dans le seau (100 → 500], qui en contient 45 (495 − 450). Il faut y avancer de 25 spans (475 − 450) sur ces 45, soit **55,6 %** du chemin — et `histogram_quantile` applique cette proportion à la **largeur** du seau :

```text
       seau de 400 ms de large, 45 spans dedans
  100 ms                    322 ms              500 ms
    |------------------------|-------------------|
  450e                     475e                 495e
    <------ 25 spans ------> <---- 20 spans ---->
              (55,6 %)

  100 + 0,556 × (500 - 100) = 322 ms
```

C'est cela, l'**interpolation linéaire** : on suppose les 45 spans espacés régulièrement entre les deux bornes, comme les graduations d'une règle. Or ils pourraient aussi bien être tous à 105 ms que tous à 495 ms — la réponse serait la même. L'erreur est donc bornée par la largeur du seau : « 322 ms » signifie surtout « entre 100 et 500 ». Seuls des seaux plus serrés améliorent la précision, et cela se règle à la production de la métrique, pas à la lecture.

**Attention au plateau.** Quand le centile dépasse la dernière borne finie, Prometheus ne renvoie pas `+Inf` mais [la borne supérieure de l'avant-dernier seau](https://prometheus.io/docs/prometheus/latest/querying/functions/#histogram_quantile). Si le plus grand seau est `le="15000"`, le panel affiche 15 000 ms : la latence *semble* plafonner à une valeur ronde, alors qu'en réalité elle est sortie de l'échelle de mesure. Les bornes réelles de votre cluster se listent en une requête, dans *Explore* — ne les déduisez pas de la documentation :

```promql
count by (le) (traces_span_metrics_duration_milliseconds_bucket{service_name="checkout"})
```

**Il mélange des opérations hétérogènes.** Tel quel, le panel confond un `GET /health` à 2 ms et un `PlaceOrder` à 800 ms. C'est le bon choix pour une vue d'ensemble du service, mais dès qu'on cherche *quoi* est lent, il faut détailler — un percentile par opération :

```promql
histogram_quantile(0.95, sum(rate(traces_span_metrics_duration_milliseconds_bucket{service_name=~"$service_name"}[2m])) by (le, span_name))
```

**Ce n'est pas la latence vue par vos utilisateurs.** Elle porte sur les spans arrivés au collecteur. Au Lab 7, le tail sampling n'en laissera passer qu'un quart : le percentile sera alors calculé sur un échantillon — et un échantillon biaisé, puisque le sampling retient précisément les erreurs et les requêtes lentes.
{{% /expand%}}

**Arrêtez-vous ici un instant : l'essentiel du lab est fait.** Une variable alimentée par les données, une requête qui s'y adapte — les deux panels suivants n'ajoutent aucune idée nouvelle, seulement la syntaxe propre à chaque datasource. Prenez donc le résultat complet tout de suite, et construisez la suite seulement s'il vous reste du temps.

4.  **Importer le dashboard de référence** — il arrive **à côté du vôtre**, sans l'écraser : son `uid` (`otel-training-service`) n'est pas celui de votre création.

```bash
. ./scripts/env.sh   # si ce n'est pas déjà fait dans ce terminal

curl -sS -X POST http://$PF_HOST:$UI_PORT/grafana/api/dashboards/db \
  -H "Content-Type: application/json" \
  -d "{\"overwrite\": true, \"dashboard\": $(cat content/1_Labs/40-otel-grafana-dashboard.json)}"

# l'URL du dashboard importé, à ouvrir directement
echo "http://$PF_HOST:$UI_PORT/grafana/d/otel-training-service"
```

Il s'intitule **« Vue service — Formation OTel »** et arrive à la racine, sans dossier : dans *Dashboards*, il se retrouve mêlé aux neuf dashboards livrés par la démo. Plutôt que de le chercher, ouvrez l'URL ci-dessus — c'est l'`uid` du dashboard, pas son titre, qui la détermine.

Vous avez maintenant sous les yeux les trois signaux d'un même service, pilotés par une seule variable : c'est l'objectif du lab. Gardez-le ouvert dans un onglet, il sert de **corrigé** pour la suite.

Deux panels supplémentaires l'attendent tout en bas, préfixés **« Bonus 1 »** et **« Bonus 2 »** : ils servent aux étapes 9 et 10, où il n'y aura rien à construire — seulement à lire.

5.  **Panel 3 — logs (OpenSearch)** *(si le temps le permet)* **:** de retour dans **votre** dashboard, ajoutez un panel de type *Logs*, datasource **OpenSearch**, requête Lucene :

```text
resource.service.name:"$service_name"
```

> 💡 **Panels vides sur `review-service` ?** C'est normal, et instructif : les services de la boutique reçoivent du trafic en permanence — le load generator s'en charge — mais **le vôtre n'en reçoit que si vous lui en envoyez**. Ses derniers logs peuvent dater de votre session précédente. Réveillez-le :
>
> ```bash
> . ./scripts/env.sh   # si ce n'est pas déjà fait dans ce terminal
> kubectl port-forward -n otel-demo --address $PF_ADDR svc/review-service $APP_PORT:8080 &
>
> for i in $(seq 1 10); do curl -s -o /dev/null http://$PF_HOST:$APP_PORT/api/reviews; done
> ```
>
> (ou postez quelques avis depuis sa page web, `http://$PF_HOST:$APP_PORT/`). Une vingtaine de secondes plus tard, les logs `Listing all reviews` remplissent le panel — et les deux panels Prometheus se garnissent de la même façon, sans requêtes il n'y a ni débit ni latence à tracer.
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
>
> Pour voir à quoi ressemblent des logs applicatifs sans attendre, ouvrez le **Demo Dashboard** livré par la démo, `http://$PF_HOST:$UI_PORT/grafana/d/W2gX2zHVk` : sa rangée *Application Log Records* montre, pour le service choisi dans sa propre variable, les 100 derniers logs et leur répartition par sévérité. Son UID vient lui aussi du chart, il est donc le même sur tous les clusters.

6.  **Panel 4 — traces (Jaeger)** *(si le temps le permet)* **:** datasource **Jaeger**, query type *Search*, service `$service_name`, limit 20.

> ⚠️ **Le panel restera vide tant que vous n'aurez pas coché *Table view***, l'interrupteur en haut de l'éditeur de panel. La visualisation par défaut est un graphe temporel : elle ne sait pas représenter une liste de traces, et n'affiche donc **rien du tout — sans message d'erreur**, ce qui laisse croire que la requête est en cause. Elle ne l'est pas : la requête ci-dessus est correcte. (Vous pouvez aussi choisir la visualisation *Table* dans le sélecteur en haut à droite ; *Table view* est simplement plus rapide.)

> 💡 Bloqué sur l'un de ces deux panels ? Ouvrez le même dans le dashboard importé, puis *Panel → Inspect → Panel JSON* : vous y lisez la configuration exacte attendue, datasource et requête comprises.

7.  **Tester la variable :** basculez `service_name` entre `frontend`, `checkout` et `review-service` — vos panels doivent suivre. Faites-en autant sur le dashboard importé, qui a les trois signaux.

8.  **Exporter votre dashboard en JSON** (*Share → Export → Save to file*) : c'est le **livrable**, à committer dans votre dépôt — même s'il ne contient que la variable et les panels Prometheus.

**Les deux bonus qui suivent ne demandent rien à construire** : leurs panels sont déjà dans le dashboard importé à l'étape 4, en bas. On les lit ensemble.

9.  **Bonus 1 — la règle d'alerte, lue sur son panel :** ouvrez **« Bonus 1 — Seuil d'alerte : p95 > 500 ms »**.

C'est le p95 de l'étape 3, avec le seuil matérialisé en rouge. Tout ce qui fait une alerte Grafana s'y lit :

* **la condition** — la ligne rouge : « p95 au-dessus de 500 ms » ;
* **la durée** — une alerte ne se déclenche pas au premier point qui dépasse, elle attend que le dépassement *dure* (le `for` de la règle, 2 min ici). C'est ce qui sépare un pic isolé d'un incident ;
* **les états** — condition vraie mais durée non écoulée : `Pending` ; durée atteinte : `Firing`, et la notification part.

Pour en faire une vraie règle, *Panel → More → New alert rule* : Grafana reprend la requête du panel, il ne reste qu'à saisir le seuil et la durée. À faire avec le formateur s'il reste du temps.

10. **Bonus 2 (avancé) — les exemplars : du point sur la courbe à la trace.** Ouvrez **« Bonus 2 — Exemplars : p95 gRPC serveur »**.

Une métrique est une **agrégation** : « 30 requêtes, p95 à 400 ms » ne dit pas *quelles* requêtes. Un **exemplar** est une mesure individuelle conservée à côté de l'agrégat, avec le `trace_id` de la requête qui l'a produite :

```text
série    : rpc_server_duration_milliseconds_bucket{service_name="checkout", rpc_method="PlaceOrder"}
exemplar : value = 75.1 (ms)   labels = {trace_id: "900ad5ea…", span_id: "08efb94d…"}
```

Grafana pose de petits marqueurs le long de la courbe : **cliquez sur l'un d'eux, puis sur le lien de la trace** — Jaeger s'ouvre sur *cette* requête précise. Au lieu de chercher dans Jaeger une trace qui ressemblerait au symptôme, c'est le symptôme qui vous donne son identifiant.

Une chose à remarquer : ce panel **ne suit pas la variable `$service_name`**, contrairement à tous les autres. Ce n'est pas un oubli.

{{%expand "Pourquoi ce panel-là, et pas ceux que vous avez construits" %}}
Il faut réunir trois conditions ; les deux premières sont remplies par la démo :

* **Prometheus stocke les exemplars** — il est démarré avec `--enable-feature=exemplar-storage` (visible dans `/api/v1/status/flags`) ; sans ce drapeau, il les jette à l'ingestion ;
* **la datasource sait où ouvrir la trace** — c'est le `"exemplarTraceIdDestinations": [{"datasourceUid": "webstore-traces"}]` de l'étape 1 : l'UID de Jaeger, et rien d'autre, fait le lien ;
* **la métrique doit en porter** — et c'est là que ça coince pour le dashboard que vous venez de construire.

Les métriques `traces_span_metrics_*` du connector `spanmetrics` n'ont **aucun** exemplar : sa configuration `{}` ne les produit pas (il faut le lui demander explicitement). Ceux de la démo viennent des **SDK des applications**, sur `rpc_server_duration_milliseconds_bucket` et `http_client_duration_milliseconds_bucket`.

Et voilà pourquoi le panel ignore `$service_name` : ces métriques n'existent que pour les services dont le SDK les exporte — sur ce cluster, `checkout`, `ad` et `product-catalog` en portent, `review-service` non. Filtrer par la variable donnerait un panel vide la plupart du temps ; sans filtre, il montre toujours quelque chose à cliquer.

Vous pouvez le constater par l'API, sans Grafana :

```bash
. ./scripts/env.sh   # si ce n'est pas déjà fait dans ce terminal
kubectl port-forward -n otel-demo --address $PF_ADDR svc/prometheus $PROM_PORT:9090 &

curl -s -G "http://$PF_HOST:$PROM_PORT/api/v1/query_exemplars" \
  --data-urlencode 'query=http_client_duration_milliseconds_bucket' \
  --data-urlencode "start=$(date -d '-1 hour' +%s)" --data-urlencode "end=$(date +%s)" \
  | head -c 400
```

Remplacez le nom par `traces_span_metrics_duration_milliseconds_bucket` : la réponse est `{"status":"success","data":[]}`.
{{% /expand%}}

{{%expand "Avancé — en obtenir sur *vos* panels (hors temps de lab)" %}}
`spanmetrics` sait produire des exemplars ; l'option est simplement désactivée par défaut. Sur le modèle du Lab 3, créez `manifests/40-otel-grafana-values.yaml` :

```yaml
opentelemetry-collector:
  config:
    connectors:
      spanmetrics:
        exemplars:
          enabled: true
```

puis empilez-le sur les values des labs précédents :

```bash
helm upgrade otel-demo open-telemetry/opentelemetry-demo \
  --version 0.40.9 -n otel-demo \
  -f manifests/values-training.yaml \
  -f manifests/30-otel-collector-values.yaml \
  -f manifests/40-otel-grafana-values.yaml
kubectl rollout status daemonset/otel-collector-agent -n otel-demo
```

Deux minutes plus tard, `calls_total` **et** l'histogramme de latence portent leurs exemplars — et votre panel « Latence p95 » devient cliquable jusqu'à la trace, pour le service de votre choix. C'est le `{}` de la configuration par défaut qui vous en privait, pas une limite du connector.

Deux réserves à connaître : un exemplar n'est gardé **que le temps d'un cycle d'export** (il n'est pas rejoué indéfiniment), et `max_per_data_point` en limite le nombre à 5 par point de mesure.
{{% /expand%}}

## Livrable

Votre dashboard « vue service » exporté en JSON, avec sa variable `service_name` et au moins un panel qu'elle pilote. Le dashboard de référence importé à l'étape 4 montre la cible complète — les trois signaux d'un même service côte à côte, plus les deux panels des bonus.
