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

Vous y retrouvez l'UID et l'URL du tableau ci-dessus, plus un champ `exemplarTraceIdDestinations` qui relie Prometheus à Jaeger. Il fait l'objet du **Lab 4.1**.

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
> * **`sum(...)`** — *combien en tout ?* spanmetrics ne tient pas un compteur par service, mais un par **opération** (`span_name`), sens d'appel (`span_kind`) et statut. Sans `sum`, le panel afficherait des dizaines de courbes ; `sum` les écrase en une seule, le débit total du service.
>
> **L'ordre compte : toujours `rate` d'abord, `sum` ensuite.** `rate` sait reconnaître qu'un compteur est reparti de zéro — un pod du collecteur qui redémarre — et corriger ; mais il ne le peut que série par série. Additionnez avant, et la baisse se lit comme une remise à zéro du total : le panel affiche alors un **pic de trafic au moment précis où un pod est mort**. La démonstration chiffrée est en fin de page.

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
histogram_quantile(0.95, sum(rate(traces_span_metrics_duration_milliseconds_bucket{service_name=~"$service_name", span_kind=~"SPAN_KIND_SERVER|SPAN_KIND_CONSUMER"}[2m])) by (le, span_kind))
```

> 💡 **Le p95 en une phrase** : 95 % des requêtes ont été **plus rapides** que la valeur affichée ; une sur vingt a été plus lente. On le préfère à la moyenne parce qu'une moyenne noie les lentes — sur 100 requêtes dont 90 à 4 ms et 10 à 500 ms, elle annonce 54 ms, une durée que personne n'a connue. Le p95, lui, affiche 500 ms : ce que vit un utilisateur sur dix.

**Et il ne coûte rien à produire.** La métrique interrogée, `traces_span_metrics_duration_milliseconds_bucket`, sort du même connector **spanmetrics** que le compteur du panel 1 : le collecteur chronomètre déjà chaque span qu'il voit passer. Personne n'a ajouté de timer dans le `review-service`, ni bibliothèque, ni ligne de code — tracer suffit. Et comme le nom et les labels sont les mêmes partout, ce panel unique donne la latence des quinze services de la boutique, quel que soit leur langage.

Ce qu'on lui demande, ici, c'est de répondre d'un coup d'œil à « ça va, ou pas ? ». Le trait rouge à 20 ms est un repère de lecture calibré sur le `review-service`, qui tourne autour de 4 ms au repos : au-delà, quelque chose a changé. Ce que ce panel mesure exactement, et le piège qu'évite son filtre `span_kind`, sont le sujet du [Lab 4 bonus]({{% relref "43-otel-spanmetrics" %}}).

6.  **Exporter votre dashboard en JSON.** Ce n'est pas dans le menu *Share*, qui ne propose que *Share internally* / *Share externally*. L'export est l'**icône ⤓ de la barre verticale, à droite du dashboard** (infobulle *Export*) : cliquez-la, puis *Export as code*. Le panneau *Export dashboard* affiche le JSON ; le bouton **Download file** l'enregistre.

    C'est le **livrable**, à committer dans votre dépôt — même s'il ne contient que la variable et vos deux panels.

## Quand le dashboard invente un pic

L'encadré de l'étape 3 posait la règle sans la démontrer. La voici, sur un incident que tous les clusters connaissent : le redémarrage d'un pod.

Deux pods de collecteur, `A` et `B`, 2 requêtes/s chacun — donc **4 req/s en réalité**, stable. Scrape toutes les 15 s. `B` redémarre à t=45 s.

<svg viewBox="0 0 920 486" width="100%" role="img" aria-label="Le pic fantome : un pod qui redemarre, vu par sum(rate) et par rate(sum)" style="max-width:920px;height:auto;display:block;margin:1.2rem auto">
<defs><marker id="ph" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6" markerHeight="6" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="#dc2626"/></marker></defs>
<text x="14" y="24" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="15.5" font-weight="700" text-anchor="start" fill="currentColor">Ce que Prometheus scrape : deux compteurs, dont l’un repart de zéro</text><line x1="80" y1="176" x2="890" y2="176" stroke="currentColor" stroke-width="1.2" opacity="0.35"/>
<line x1="96" y1="176" x2="96" y2="181" stroke="currentColor" stroke-width="1.2" opacity="0.35"/>
<text x="96" y="197" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="12.5" font-weight="normal" text-anchor="middle" fill="currentColor" opacity="0.8">0 s</text><line x1="246" y1="176" x2="246" y2="181" stroke="currentColor" stroke-width="1.2" opacity="0.35"/>
<text x="246" y="197" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="12.5" font-weight="normal" text-anchor="middle" fill="currentColor" opacity="0.8">15 s</text><line x1="396" y1="176" x2="396" y2="181" stroke="currentColor" stroke-width="1.2" opacity="0.35"/>
<text x="396" y="197" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="12.5" font-weight="normal" text-anchor="middle" fill="currentColor" opacity="0.8">30 s</text><line x1="546" y1="176" x2="546" y2="181" stroke="currentColor" stroke-width="1.2" opacity="0.35"/>
<text x="546" y="197" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="12.5" font-weight="normal" text-anchor="middle" fill="currentColor" opacity="0.8">45 s</text><line x1="696" y1="176" x2="696" y2="181" stroke="currentColor" stroke-width="1.2" opacity="0.35"/>
<text x="696" y="197" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="12.5" font-weight="normal" text-anchor="middle" fill="currentColor" opacity="0.8">60 s</text><line x1="546" y1="44" x2="546" y2="182" stroke="#dc2626" stroke-width="1.6" stroke-dasharray="5 4"/>
<text x="552" y="56" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="13.5" font-weight="700" text-anchor="start" fill="#dc2626">B redémarre</text><polyline points="96,83 246,80 396,77 546,74 696,71" fill="none" stroke="#3b82f6" stroke-width="2.8"/>
<polyline points="96,101 246,99 396,96 516,93" fill="none" stroke="#10b981" stroke-width="2.8"/>
<polyline points="516,93 516,176" fill="none" stroke="#10b981" stroke-width="2.4" stroke-dasharray="4 3"/>
<polyline points="546,176 696,173" fill="none" stroke="#10b981" stroke-width="2.8"/>
<circle cx="96" cy="83" r="3.6" fill="#3b82f6"/>
<circle cx="246" cy="80" r="3.6" fill="#3b82f6"/>
<circle cx="396" cy="77" r="3.6" fill="#3b82f6"/>
<circle cx="546" cy="74" r="3.6" fill="#3b82f6"/>
<circle cx="696" cy="71" r="3.6" fill="#3b82f6"/>
<circle cx="96" cy="101" r="3.6" fill="#10b981"/>
<circle cx="246" cy="99" r="3.6" fill="#10b981"/>
<circle cx="396" cy="96" r="3.6" fill="#10b981"/>
<circle cx="546" cy="176" r="3.6" fill="#10b981"/>
<circle cx="696" cy="173" r="3.6" fill="#10b981"/>
<text x="712" y="76.46666666666667" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="13.5" font-weight="700" text-anchor="start" fill="#3b82f6">pod A</text><text x="712" y="178.2" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="13.5" font-weight="700" text-anchor="start" fill="#10b981">pod B</text><text x="538" y="64.26666666666667" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="12.5" font-weight="700" text-anchor="end" fill="#3b82f6">1090</text><text x="538" y="170" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13" font-weight="700" text-anchor="end" fill="#10b981">0</text><text x="14" y="218" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="13" font-weight="normal" text-anchor="start" fill="currentColor" opacity="0.85">Les deux pods servent 2 req/s chacun : le trafic réel vaut 4 req/s, du début à la fin.</text><rect x="14" y="244" width="438" height="168" rx="6" fill="none" stroke="currentColor" stroke-opacity="0.28"/>
<text x="30" y="272" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="15" font-weight="700" text-anchor="start" fill="#10b981">sum(rate(...))</text><text x="30" y="292" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="12.5" font-weight="normal" text-anchor="start" fill="currentColor" opacity="0.8">rate corrige chaque pod séparément</text><line x1="72" y1="388" x2="436" y2="388" stroke="currentColor" stroke-width="1" stroke-dasharray="3 3" opacity="0.3"/>
<text x="64" y="392" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="12" font-weight="normal" text-anchor="end" fill="currentColor" opacity="0.8">4/s</text><rect x="468" y="244" width="438" height="168" rx="6" fill="none" stroke="currentColor" stroke-opacity="0.28"/>
<text x="484" y="272" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="15" font-weight="700" text-anchor="start" fill="#dc2626">rate(sum(...))</text><text x="484" y="292" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="12.5" font-weight="normal" text-anchor="start" fill="currentColor" opacity="0.8">la baisse du total est prise pour un reset</text><line x1="526" y1="388" x2="890" y2="388" stroke="currentColor" stroke-width="1" stroke-dasharray="3 3" opacity="0.3"/>
<text x="518" y="392" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="12" font-weight="normal" text-anchor="end" fill="currentColor" opacity="0.8">4/s</text><polyline points="72,388 200,388 250,388 268,400 310,400 328,388 436,388" fill="none" stroke="#10b981" stroke-width="3"/>
<text x="289" y="418" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="12.5" font-weight="700" text-anchor="middle" fill="#10b981">2/s</text><polyline points="526,388 660,388 700,388" fill="none" stroke="#dc2626" stroke-width="3"/>
<polyline points="700,388 730,322" fill="none" stroke="#dc2626" stroke-width="3" marker-end="url(#ph)"/>
<polyline points="734,322 764,388 890,388" fill="none" stroke="#dc2626" stroke-width="3"/>
<text x="732" y="310" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="14.5" font-weight="700" text-anchor="middle" fill="#dc2626">≈ 73/s</text><text x="14" y="442" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="13.5" font-weight="600" text-anchor="start" fill="currentColor">Le creux est la vérité : la moitié de la</text><text x="14" y="462" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="13.5" font-weight="600" text-anchor="start" fill="currentColor">capacité était absente pendant 15 s.</text><text x="468" y="442" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="13.5" font-weight="600" text-anchor="start" fill="currentColor">Un pic de trafic au moment précis où un</text><text x="468" y="462" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="13.5" font-weight="600" text-anchor="start" fill="currentColor">pod est mort — et il n’y a eu aucun trafic.</text></svg>

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

Cette écriture-là, PromQL la rend d'ailleurs difficile à commettre. Ce qui se transpose, c'est le réflexe : **un pic sur un dashboard peut être un artefact du calcul et pas un événement**. Devant une valeur spectaculaire, la première question à se poser est de savoir si elle décrit le système ou la façon dont on l'interroge.

## Pour aller plus loin

* [**Lab 4.1 — Lire un histogramme : de la heatmap au p95**]({{% relref "41-otel-histogramme" %}}) — le PromQL des seaux, comment une heatmap se construit, et pourquoi le p95 n'en est que le résumé. La théorie derrière le panel « Latence p95 ».
* [**Lab 4.2 — Exemplars : du point de métrique à la trace**]({{% relref "42-otel-exemplars" %}}) — le chaînon qui manque entre le p95 et Jaeger, sur un dashboard livré par la démo. Rien à construire, tout à lire.
* [**Lab 4 bonus — Le dashboard spanmetrics de la démo**]({{% relref "43-otel-spanmetrics" %}}) — le trio RED pour tous les services, et le piège que le filtre `span_kind` évite.

## Livrable

Votre dashboard « vue service » exporté en JSON, avec sa variable `service_name` et au moins un panel qu'elle pilote. Le dashboard de référence importé au bloc « Solution » montre la cible complète — les trois signaux d'un même service côte à côte.
