---
title: 'Lab 3 — Configuration du collecteur'
date: 2026-07-06T15:15:00+02:00
draft: false
weight: 30
tags: ["OpenTelemetry", "collecteur", "receivers", "Prometheus"]
---

Le collecteur OpenTelemetry est le cœur de la chaîne : il **reçoit** (receivers), **transforme** (processors) et **exporte** (exporters) la télémétrie. Dans ce lab, vous allez lire sa configuration réelle, puis l'enrichir pour collecter des **métriques système** (hostmetrics) et des **métriques produit** (PostgreSQL) — sans toucher aux applications.

> 💡 Dans la démo, le collecteur est déployé par Helm : modifier sa configuration = modifier les *values* du chart + `helm upgrade`. Pas de rebuild, pas de redéploiement manuel.

## Prérequis

* Labs 1 et 2 terminés (stack + `review-service` déployés).
* Le port-forward des UIs actif (`./scripts/open-ui.sh`).
* **Les variables de la formation chargées dans votre shell** :

```bash
# exporte PROM_PORT, ZPAGES_PORT, APP_PORT, PF_ADDR, PF_HOST
. ./scripts/env.sh

# doit afficher : 9090 55679
echo "$PROM_PORT $ZPAGES_PORT"
```

> Sur le serveur partagé, gardez `--address $PF_ADDR` dans les `port-forward` et `$PF_HOST` dans les URLs, comme dans les commandes ci-dessous : c'est ce qui donne à chaque participant sa propre adresse d'écoute. Sans lui, deux participants se disputent le même port et le second `port-forward` échoue.
>
> Les deux ne sont pas interchangeables : `--address` **n'accepte qu'une IP** (`kubectl` répond `localhost3 is not a valid IP`), là où une URL veut un nom. D'où `$PF_ADDR` pour écouter, `$PF_HOST` pour joindre.

## Étapes

### 1. Lire la configuration réelle du collecteur

#### a. Où vit cette configuration ?

```
values Helm  ──►  ConfigMap otel-collector-agent, clé « relay »
             ──►  montée dans le pod sur /conf
             ──►  lue au démarrage : otelcol --config=/conf/relay.yaml
```

Le collecteur est un **DaemonSet** (un pod par nœud) et sa configuration n'est qu'un **fichier YAML** ; tout ce que fait Helm, c'est le générer. Affichez-le :

```bash
kubectl get configmap otel-collector-agent -n otel-demo -o jsonpath='{.data.relay}' | less
```

> 💡 `-o yaml` renverrait l'objet ConfigMap complet, avec la configuration noyée dans une longue chaîne YAML échappée. `-o jsonpath='{.data.relay}'` extrait la seule clé utile : son contenu est **exactement** le fichier `/conf/relay.yaml` lu par le collecteur.

> ⚠️ **Ne cherchez pas de logique dans l'ordre des blocs.** Ce fichier n'a pas été écrit à la main : il est généré automatiquement par Helm. Vous y verrez ainsi la sortie (`exporters`) avant l'entrée (`receivers`). Aucune importance : le collecteur lit un fichier YAML, où l'ordre des blocs ne change rien. Un seul endroit décrit le flux réel de la donnée — `service.pipelines`, tout en bas du fichier. **C'est par lui qu'il faut commencer la lecture**, puis remonter voir la définition de chaque composant qu'il cite.

#### b. Le vérifier depuis l'intérieur du pod (bonus)

L'image du collecteur est **distroless** : ni shell ni `cat`, donc `kubectl exec` est inutilisable. On lui adjoint un **conteneur éphémère** qui partage ses namespaces :

```bash
POD=$(kubectl get pod -n otel-demo -l app.kubernetes.io/name=opentelemetry-collector \
        -o jsonpath='{.items[0].metadata.name}')

kubectl debug -it -n otel-demo "$POD" \
  --image=busybox --target=opentelemetry-collector --profile=sysadmin
```

Puis, dans le shell obtenu :

```sh
# le fichier de configuration réellement lu par le collecteur
cat /proc/1/root/conf/relay.yaml

# les variables d'environnement du collecteur
cat /proc/1/environ | tr '\0' '\n' | grep MY_POD_IP
```

> `--profile=sysadmin` partage le namespace PID du pod cible : le processus `1` est le collecteur, et `/proc/1/root` donne accès à **son** système de fichiers depuis busybox. Vous lisez le fichier tel qu'il est monté — la preuve que ConfigMap et configuration effective coïncident.
>
> `MY_POD_IP` est injecté par le chart via la *downward API* ; c'est la variable que la configuration référence sous la forme `${env:MY_POD_IP}`. Le collecteur écoute donc sur **l'IP du pod**, pas sur `0.0.0.0`.

Sortez avec `exit`. Le conteneur éphémère ne redémarre pas, mais reste attachable tant que le pod vit (`kubectl attach ... -c <nom-généré> -i -t`) ; il disparaît avec le pod.

> 🚫 N'utilisez **pas** `kubectl debug --copy-to=...` ici. Cette variante crée un **pod indépendant**, copie du collecteur, qui réclame les mêmes `hostPort` (4317, 4318, 14250, 14268, 9411). Il reste `Pending` tant que le DaemonSet tourne, donc invisible — mais au prochain `helm upgrade` il s'empare des ports libérés et le nouveau pod du collecteur ne peut plus être planifié. Si vous en avez créé un : `kubectl delete pod <nom> -n otel-demo`.

#### c. Les sections qui comptent

Voici la configuration de la démo, **condensée et remise dans l'ordre logique** du flux de données — de l'entrée vers la sortie (dans le fichier réel, les blocs sont dans un tout autre ordre). Les clés sans valeur sont celles dont le détail a été coupé :

```yaml
# ---------- 1. RECEIVERS : par où la donnée ENTRE ----------
receivers:

  # LE receiver standard : les applications lui POUSSENT leur télémétrie en OTLP
  otlp:
    protocols:
      grpc:
        # la cible de review-service (Lab 2)
        endpoint: ${env:MY_POD_IP}:4317
      http:
        # le même receiver, en HTTP : utilisé par les applications de la boutique qui
        # parlent OTLP/HTTP (accounting, ad, email...) et par les traces émises par le
        # navigateur du client, relayées par frontend-proxy
        endpoint: ${env:MY_POD_IP}:4318
        cors:
          # sans cette autorisation, le navigateur refuserait d'envoyer ses traces
          allowed_origins: ["http://*", "https://*"]

  # receiver « produit », en mode PULL : c'est LE MODÈLE À SUIVRE à l'étape 3
  kafkametrics:
    brokers: [kafka:9092]
    scrapers: [brokers, topics, consumers]
    collection_interval: 10s

  # métriques des pods du nœud (personne ne l'a écrit : preset du chart)
  kubeletstats:

  # état des objets Kubernetes (personne ne l'a écrit : preset du chart)
  k8s_cluster:

  # le collecteur scrape ses propres métriques internes, exposées sur son port 8888
  # ...mais regardez le bloc `service` : ce receiver n'est cité dans aucun pipeline
  prometheus:

  # protocoles historiques encore acceptés en entrée
  jaeger:
  zipkin:

# ---------- 2. PROCESSORS : ce qui est appliqué ENTRE l'entrée et la sortie ----------
processors:

  # garde-fou mémoire : jette de la donnée plutôt que de laisser le pod se faire tuer
  memory_limiter:
    check_interval: 5s
    limit_percentage: 80
    spike_limit_percentage: 25

  # enrichit chaque donnée avec le namespace / pod / deployment... qui l'a émise
  k8sattributes:

  # ajoute les attributs de la machine et de l'environnement
  resourcedetection:
    detectors: [env, system]

  # recopie k8s.pod.uid dans l'attribut standard service.instance.id : les 3 replicas
  # d'un même service cessent d'être confondus, chacun devient une instance identifiable
  resource:

  # OTTL : normalise les noms de spans du frontend
  transform:
    error_mode: ignore
    trace_statements:
      - context: span
        statements:
          - set(span.attributes["http.route"], "/api/cart")
            where IsMatch(span.attributes["http.target"], "\\/api\\/cart")

  # regroupe la donnée en lots, juste avant l'export
  batch:

# ---------- 3. CONNECTORS : la sortie d'un pipeline devient l'entrée d'un autre ----------
connectors:

  # branché en EXPORTER du pipeline traces et en RECEIVER du pipeline metrics : il compte
  # les spans et mesure leur durée, puis en publie des métriques (calls_total,
  # duration_milliseconds) que vous tracerez au Lab 4. `{}` = configuration par défaut.
  spanmetrics: {}

# ---------- 4. EXPORTERS : par où la donnée SORT ----------
exporters:

  # les traces, vers Jaeger
  otlp/jaeger:
    endpoint: jaeger:4317

  # les métriques, vers Prometheus
  otlphttp/prometheus:
    endpoint: http://prometheus:9090/api/v1/otlp

  # les logs, vers OpenSearch
  opensearch:
    http:
      endpoint: http://opensearch:9200
    logs_index: otel-logs

  # écrit la donnée dans les logs du collecteur : la mise au point du pauvre
  debug: {}

# ---------- 5. EXTENSIONS : des services rendus HORS du flux de données ----------
extensions:

  # sonde HTTP de vivacité, interrogée par Kubernetes
  health_check:
    endpoint: ${env:MY_POD_IP}:13133

  # le collecteur est un DaemonSet : ceci désigne celui qui interrogera l'API Kubernetes
  k8s_leader_elector/k8s_cluster:
    auth_type: serviceAccount

  # C'est ici que vous déclarerez zpages à l'étape 3.

# ---------- 6. SERVICE : ce qui est RÉELLEMENT ACTIF ----------
service:
  extensions: [health_check, k8s_leader_elector/k8s_cluster]
  pipelines:
    traces:
      receivers:  [otlp, jaeger, zipkin]
      processors: [k8sattributes, memory_limiter, resourcedetection, resource, transform, batch]
      exporters:  [otlp/jaeger, debug, spanmetrics]
    metrics:
      receivers:  [otlp, kafkametrics, spanmetrics, kubeletstats, k8s_cluster]
      processors: [k8sattributes, memory_limiter, resourcedetection, resource, batch]
      exporters:  [otlphttp/prometheus, debug]
    logs:
      receivers:  [otlp]
      processors: [k8sattributes, memory_limiter, resourcedetection, resource, batch]
      exporters:  [opensearch, debug]
```

> 🔑 **La règle d'or** : un composant déclaré dans `receivers`, `processors`, `exporters` ou `extensions` n'est qu'une *définition*. Il ne s'exécute que s'il est **cité dans `service`** — dans un pipeline pour les trois premiers, dans `service.extensions` pour les extensions. C'est l'oubli n°1 quand on configure un collecteur, et vous ferez les deux à l'étape 3 : brancher vos receivers dans le pipeline `metrics`, et activer `zpages` dans `service.extensions`.

Répondez maintenant, configuration sous les yeux. Chaque question a sa réponse juste en dessous : cherchez d'abord, dépliez ensuite.

**a. Par quel receiver les traces de `review-service` entrent-elles, et sur quelle *adresse* le collecteur écoute-t-il ?**

{{%expand "Réponse" %}}
Par le receiver **`otlp`**, sur `${env:MY_POD_IP}:4317` (gRPC) et `:4318` (HTTP) : le collecteur écoute donc sur **l'IP de son pod**. Les applications ne connaissent pas cette IP — elles s'adressent au Service Kubernetes `otel-collector`, qui redirige vers ce pod. C'est lui que pointe `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317` au Lab 2. Les receivers `jaeger` et `zipkin` sont là pour les applications non OTLP.
{{% /expand%}}

**b. Vers quels backends partent les traces, les métriques, les logs ? Quel composant apparaît *à la fois* en exporter et en receiver ?**

{{%expand "Réponse" %}}
Traces → **`otlp/jaeger`**, métriques → **`otlphttp/prometheus`**, logs → **`opensearch`** ; l'exporter `debug` est branché partout pour la mise au point.

Le composant présent des deux côtés est le connector **`spanmetrics`** : *exporter* du pipeline `traces`, *receiver* du pipeline `metrics`. Chaque span qui sort du pipeline `traces` y entre donc une seconde fois, sous forme de chiffres : `spanmetrics` compte les spans par service et par opération et mesure leur durée, puis publie deux métriques — `calls_total` (le débit) et `duration_milliseconds` (la latence, sous forme d'histogramme). Résultat : tout service tracé obtient gratuitement ses métriques de débit et de latence, sans une ligne d'instrumentation de plus — vous les tracerez dans Grafana au Lab 4.
{{% /expand%}}

**c. Un receiver de « métriques produit » (mode *pull*) est déjà configuré — lequel ?**

{{%expand "Réponse" %}}
Le receiver **`kafkametrics`**, qui interroge le broker Kafka toutes les 10 s. Sa structure est celle qu'il faudra écrire pour PostgreSQL à l'étape 3 : un endpoint, des identifiants, un `collection_interval`.
{{% /expand%}}

**d. Un receiver est *déclaré mais ne tourne pas* : lequel, et à quoi le voit-on ?**

{{%expand "Réponse" %}}
Le receiver **`prometheus`**. Il est bien défini — il scrape le port `8888` du collecteur, celui où le collecteur publie ses propres métriques internes (spans reçus, données refusées, exports en échec) — mais son nom n'apparaît dans **aucun** pipeline de `service`. Il est donc inerte : rien ne le démarre. C'est la règle d'or prise sur le fait, dans une configuration livrée par un chart officiel.
{{% /expand%}}

**e. Dans le pipeline `traces`, dans quel ordre les processors s'appliquent-ils, et pourquoi `batch` est-il en dernier ?**

{{%expand "Réponse" %}}
Ordre : `k8sattributes` → `memory_limiter` → `resourcedetection` → `resource` → `transform` → `batch`. Soit : le garde-fou mémoire en tête (à une entorse près, voir plus bas), l'enrichissement ensuite, le regroupement en dernier.

Il manque un maillon par rapport à l'ordre recommandé : entre le garde-fou et l'enrichissement viennent normalement les processors qui **jettent** de la donnée — filtrage, échantillonnage — car il est inutile d'enrichir ce qu'on s'apprête à écarter. La démo n'en configure aucun ; vous en ajouterez un au Lab 7 avec `tail_sampling`.

> 📌 **`batch` en dernier, vraiment ?** Le [schéma officiel du collecteur](https://opentelemetry.io/docs/collector/img/otel-collector.svg) montre `Batch` **en tête** de la chaîne de processors : c'est une illustration générique de la notion de pipeline, pas une prescription d'ordre. La recommandation est donnée par le [README des processors](https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/README.md) : `memory_limiter` en premier, puis les processors qui **jettent** de la donnée (filtrage, échantillonnage), puis ceux qui l'**enrichissent**, et **`batch` en dernier** — inutile de dépenser du CPU à regrouper des données qui seront ensuite écartées ou modifiées. Les trois pipelines de la démo respectent cet ordre.
>
> Seule entorse : le preset `kubernetesAttributes` du chart insère `k8sattributes` **avant** `memory_limiter`, alors que la recommandation le place après. Sans conséquence ici, ce processor n'accumulant pas de données — mais c'est exactement le genre de détail que la lecture d'une configuration réelle apprend à repérer.
{{% /expand%}}

Deux détails à ne pas manquer en refermant cette configuration : le processor **`transform`** et ses instructions **OTTL** qui normalisent les noms de spans du frontend — un exemple réel du langage vu en cours — ainsi que `kubeletstats` et `k8s_cluster` : personne ne les a écrits, ce sont des **presets** du chart Helm qui les ont ajoutés.

### 2. Constater ce qui manque dans Prometheus

```bash
. ./scripts/env.sh   # si ce n'est pas déjà fait dans ce terminal
kubectl port-forward -n otel-demo --address $PF_ADDR svc/prometheus $PROM_PORT:9090 &

# l'URL à ouvrir, variables résolues — à copier dans le navigateur
echo "http://$PF_HOST:$PROM_PORT"
```

Ouvrez l'URL affichée (`http://localhost:9090` sur un poste individuel) et cherchez dans l'autocomplétion :

| Recherche | Résultat | Pourquoi |
| --- | --- | --- |
| `kafka_` | des métriques ✔ | le receiver `kafkametrics` du collecteur les collecte |
| `system_` | des métriques ✔ — **mais pas là où vous croyez** | voir le piège ci-dessous |
| `system_cpu_load_average_15m` | rien ✘ | seul le scraper `load` de `hostmetrics` produit la charge de la machine |
| `postgresql_` | rien ✘ | aucun receiver n'interroge la base |

> ⚠️ **Le piège du préfixe.** `system_*` n'est pas vide, alors que `hostmetrics` n'est pas configuré : ces séries sont émises par trois applications Python de la boutique, dont le SDK embarque une instrumentation « system metrics ». Elles mesurent donc bel et bien la machine — mais **chacune dans son coin, et sous son propre nom**. Le nom d'une métrique ne suffit donc pas — regardez qui l'envoie :
>
> ```promql
> count by (job) (system_cpu_time_seconds_total)
> ```
>
> Vous n'obtenez que des applications (`otel-demo/load-generator`...) : dans Prometheus, `job` identifie le service émetteur — c'est `service.namespace/service.name`, les attributs que l'application déclare. Trois applications publient donc **trois copies** de la même mesure, étiquetées à leur nom : rien ne dit au lecteur qu'il s'agit du nœud, et une quatrième application ajouterait une quatrième copie. Comparez `sum by (job) (system_cpu_time_seconds_total{state="idle"})` : les totaux sont identiques à 0,01 % près, c'est bien la même machine mesurée plusieurs fois.
>
> Cette mesure de rencontre est en plus **incomplète** : le SDK Python publie 4 états CPU (`idle`, `irq`, `system`, `user`) là où `hostmetrics` en publie 8 (`nice`, `steal`, `wait`... s'y ajoutent), d'où 64 séries par application contre 128 pour le collecteur — 16 CPU × 4 contre 16 × 8. Et surtout, elle ignore la **charge** : c'est pourquoi le critère du lab est `system_cpu_load_average_15m`, qu'aucune de ces applications ne produit.

### 3. Écrire le fichier de values qui ajoute les deux receivers

Créez `manifests/30-otel-collector-values.yaml`. Il doit ajouter au collecteur :
* un receiver **`hostmetrics`** (scrapers `cpu`, `memory`, `load`, `disk`, `network`) ;
* un receiver **`postgresql`** pointé sur la base de la boutique (service `postgresql:5432`, user `root`, mot de passe `otel`) — celle-là même qu'utilise votre `review-service` ;
* l'extension **`zpages`** (pages de debug du collecteur) ;
* et il doit **brancher les deux receivers dans le pipeline `metrics`**.

> 💡 **D'où vient `zpages` ?** C'est un composant **déjà embarqué dans le binaire** du collecteur (image `otel/opentelemetry-collector-contrib`), simplement inactif dans la configuration de la démo : il n'y a rien à installer, seulement à déclarer — comme `hostmetrics` et `postgresql`, eux aussi fournis par l'image. Et comme toute extension, `zpages` ne participe pas au traitement de la télémétrie : il expose un serveur HTTP **sur le collecteur lui-même**, dont les pages affichent les composants réellement chargés. Vous l'ouvrirez à l'étape 5. Sa documentation officielle : [README de l'extension `zpages`](https://github.com/open-telemetry/opentelemetry-collector/blob/main/extension/zpagesextension/README.md).

> ⚠️ En YAML Helm, une liste redéfinie **remplace** la liste d'origine : le pipeline `metrics` doit re-lister *tous* les receivers que vous voulez conserver, pas seulement les nouveaux. (`kubeletstats` et `k8s_cluster` font exception : les presets du chart les ré-ajoutent après votre liste.)

{{%expand "Réponse" %}}
Le fichier de référence est [`30-otel-collector-values.yaml`](../30-otel-collector-values.yaml), livré dans le dépôt. Si vous préférez partir de lui plutôt que d'écrire le vôtre, **copiez-le à l'emplacement attendu par les commandes qui suivent** :

```bash
cp content/1_Labs/30-otel-collector-values.yaml manifests/
```

Son contenu :

```yaml
opentelemetry-collector:
  config:
    receivers:
      hostmetrics:
        collection_interval: 10s
        scrapers:
          cpu:
          memory:
          load:
          disk:
          network:
      postgresql:
        endpoint: postgresql:5432
        username: root
        password: otel
        databases:
          - otel
        collection_interval: 10s
        tls:
          insecure: true
    extensions:
      zpages:
        endpoint: 0.0.0.0:55679
    service:
      extensions: [health_check, zpages]
      pipelines:
        metrics:
          receivers: [otlp, kafkametrics, spanmetrics, hostmetrics, postgresql]
```
{{% /expand%}}

### 4. Appliquer la nouvelle configuration

```bash
helm upgrade otel-demo open-telemetry/opentelemetry-demo \
  --version 0.40.9 -n otel-demo \
  -f manifests/values-training.yaml \
  -f manifests/30-otel-collector-values.yaml

kubectl rollout status daemonset/otel-collector-agent -n otel-demo
```

> `helm upgrade` régénère la ConfigMap et redémarre le collecteur. Les values s'empilent : le fichier de la formation, puis le vôtre. **Gardez `manifests/30-otel-collector-values.yaml`** : les labs 6, 7 et 8 le rempileront à chaque `helm upgrade`, en plus de leur propre fichier.

Relisez la ConfigMap comme à l'étape 1 pour voir le résultat de votre travail :

```bash
kubectl get configmap otel-collector-agent -n otel-demo -o jsonpath='{.data.relay}' \
  | grep -A4 -E '^  (hostmetrics|postgresql|zpages):'
```

### 5. Observer le pipeline dans zPages

```bash
. ./scripts/env.sh   # si ce n'est pas déjà fait dans ce terminal
kubectl port-forward -n otel-demo --address $PF_ADDR daemonset/otel-collector-agent $ZPAGES_PORT:55679 &

# l'URL à ouvrir, variables résolues — à copier dans le navigateur
echo "http://$PF_HOST:$ZPAGES_PORT/debug/pipelinez"
```

Ouvrez l'URL affichée : vos deux receivers doivent apparaître dans le pipeline `metrics`.

> zPages affiche les composants **réellement chargés** par le collecteur, là où la ConfigMap ne montre que ce qu'on lui a demandé. Le pipeline `metrics` liste donc aussi `kubeletstats` et `k8s_cluster`, ajoutés par les presets du chart — c'est normal, vous ne les avez pas perdus.

### 6. Vérifier dans Prometheus

Reprenez le tableau de l'étape 2, avec les mêmes recherches — sur l'onglet Prometheus **rechargé**, une trentaine de secondes après la fin du `rollout status` de l'étape 4 : les deux receivers scrutent dès le démarrage du collecteur, mais celui-ci doit d'abord être redéployé.

| Recherche | Avant | Après |
| --- | --- | --- |
| `system_cpu_load_average_15m` | rien ✘ | présent ✔ — la charge du **nœud** |
| `postgresql_` | rien ✘ | présent ✔ |
| `count by (job) (system_cpu_time_seconds_total)` | uniquement des applications | une ligne de plus, mais **sans nom de job** — c'est le collecteur |

> ⚠️ **Pourquoi cette ligne est-elle vide ?** Prometheus l'affiche `{}`, sans étiquette. Rappelez-vous l'étape 2 : `job` vaut `service.namespace/service.name`, deux attributs que **l'application émettrice** déclare. Or `hostmetrics` ne mesure aucune application — il mesure une machine — et le collecteur ne lui prête pas son propre nom. Ces séries n'ont donc pas de `job` du tout, seulement un `host_name` : celui du pod collecteur. Pour les isoler :
>
> ```promql
> system_cpu_time_seconds_total{job=""}
> ```
>
> (en PromQL, un label absent se sélectionne avec la chaîne vide). C'est vrai aussi de vos métriques PostgreSQL : elles n'ont pas de `job`, leur repère d'origine est `instance="postgresql:5432"`.

Générez ensuite quelques avis : c'est votre `review-service` du Lab 2 qui écrit dans cette base.

```bash
. ./scripts/env.sh   # si ce n'est pas déjà fait dans ce terminal
# relancez le port-forward du Lab 2 s'il n'est plus actif
kubectl port-forward -n otel-demo --address $PF_ADDR svc/review-service $APP_PORT:8080 &

# l'URL à ouvrir, variables résolues — à copier dans le navigateur
echo "http://$PF_HOST:$APP_PORT/"
```

Ouvrez l'URL affichée et postez **une dizaine d'avis** en cliquant sur *Post review*. Chaque clic est un `INSERT` dans la table `reviews` ; le compteur en haut de la liste vous dit combien elle en contient.

{{%expand "Sans navigateur : les mêmes avis en curl" %}}
```bash
for i in $(seq 1 10); do
  curl -s -o /dev/null -X POST http://$PF_HOST:$APP_PORT/api/reviews \
    -H "Content-Type: application/json" \
    -d "{\"productId\": \"OLJCESPC7Z\", \"rating\": 5, \"comment\": \"Avis numéro $i\", \"userEmail\": \"jean.dupont@example.com\", \"userName\": \"Jean Dupont\"}"
done
```
{{% /expand%}}

Une trentaine de secondes plus tard, dans Prometheus :

```promql
postgresql_rows{postgresql_table_name="public.reviews", state="live"}
```

La valeur a augmenté de 10 : ce sont vos avis, comptés cette fois **par le collecteur** et non par l'application. Le compteur d'écritures de la même table dit la même chose, `ins` par `ins` :

```promql
postgresql_operations_total{postgresql_table_name="public.reviews", operation="ins"}
```

> ⚠️ **Ne guettez pas `postgresql_commits_total`** pour y voir vos avis : la boutique écrit en base sans discontinuer — le load generator passe des commandes, `accounting` les enregistre — et `rate(postgresql_commits_total[1m])` tourne autour de 3 commits/s. Vos dix écritures s'y noient. Un compteur global ne dit jamais **qui** écrit : c'est le label `postgresql_table_name` qui vous ramène à votre service. Attention à ne pas confondre les deux tables d'avis de la base : `public.reviews` est celle de **votre** `review-service`, `reviews.productreviews` est celle du service `product-reviews` livré avec la démo.

{{%expand "Réponse" %}}
#### Les métriques apparues

Les noms suivent les conventions sémantiques OTel, traduites en noms Prometheus :
* `system_cpu_load_average_1m` / `_5m` / `_15m`, à côté des séries déjà présentes `system_cpu_time_seconds_total`, `system_memory_usage_bytes`, `system_network_io_bytes_total`...
* `postgresql_backends`, `postgresql_commits_total`, `postgresql_operations_total`, `postgresql_rows`, `postgresql_blocks_read_total`, `postgresql_db_size_bytes`, `postgresql_table_size_bytes`...

Côté système, c'est bien `system_cpu_load_average_15m` qui prouve que votre receiver fonctionne : les autres `system_*` existaient déjà avant l'étape 4 (cf. le piège de l'étape 2).

#### Lire une série jusqu'au bout

Le nom d'une métrique dit *quoi* ; ce sont les labels qui disent *de quoi* et *par qui*. Cliquez sur une série de `postgresql_operations_total` pour la voir en entier :

```promql
postgresql_operations_total{operation="ins", postgresql_table_name="public.reviews",
  postgresql_database_name="otel", instance="postgresql:5432",
  service_instance_id="postgresql:5432", host_name="otel-collector-agent-XXXXX"}
```

| Label | Ce qu'il vous apprend |
| --- | --- |
| `operation` | le type d'écriture compté : `ins` (insert), `upd`, `del`, `hot_upd` |
| `postgresql_table_name` | la table — `public.reviews` est celle de **votre** `review-service` |
| `postgresql_database_name` | la base interrogée |
| `instance`, `service_instance_id` | **ce qui est mesuré** : l'endpoint que vous avez écrit dans votre fichier de values |
| `host_name` | **ce qui a mesuré** : le pod du collecteur — pas la base |

Les deux dernières lignes sont la clé : une métrique produite par un receiver *pull* décrit une machine (`instance`) mais est estampillée par celle qui l'a collectée (`host_name`). C'est aussi pourquoi ces séries n'ont **pas** de label `job` : personne ne les a déclarées au nom d'un service.

#### Comment le receiver `postgresql` s'y prend

Il ne lit **aucun log** et n'installe **rien** dans la base. Toutes les 10 s, il ouvre une connexion SQL avec les identifiants de votre fichier de values et interroge les vues statistiques que PostgreSQL tient à jour en permanence pour lui-même (`pg_stat_database`, `pg_stat_user_tables`, `pg_locks`...). Vous pouvez le prendre sur le fait, depuis la base :

```bash
# l'IP du pod collecteur, pour reconnaître ses lignes
kubectl get pods -n otel-demo -o wide | grep otel-collector-agent

kubectl exec -n otel-demo deploy/postgresql -- psql -U root -d otel -c "
SELECT client_addr,
       date_trunc('second', now() - query_start) AS il_y_a,
       substring(query, 1, 45) AS derniere_requete
  FROM pg_stat_activity
 WHERE backend_type = 'client backend' AND client_addr IS NOT NULL
 ORDER BY query_start DESC;"
```

Trois lignes portent l'IP du collecteur, **toutes du même âge** : un scrape, trois connexions qui travaillent de front — typiquement les bases (`pg_stat_database`), les fonctions (`pg_stat_user_functions`) et les verrous (`pg_locks`). Relancez la commande une poignée de secondes plus tard : leur âge est retombé, c'est le `collection_interval: 10s` de votre fichier de values que vous regardez battre. C'est tout le secret d'un receiver *pull* : du SQL ordinaire, exécuté à intervalle régulier.

> 💡 **Pourquoi les voit-on en permanence ?** Le receiver ne se reconnecte pas à chaque collecte : ses connexions sont **persistantes** — ajoutez `pid, state, now()-backend_start` à la requête et vous les retrouverez avec les mêmes PID, ouvertes depuis des heures, `idle` entre deux scrapes. Or `pg_stat_activity` conserve le texte de la **dernière** requête d'une connexion même inactive. C'est donc l'écho du dernier scrape que vous lisez, pas un historique : ce texte change d'une fois sur l'autre selon la requête qui s'est terminée en dernier.

#### Ce que vous n'avez pas eu à faire

Ni PostgreSQL ni votre `review-service` n'ont été touchés : pas d'extension installée dans la base, pas d'agent à côté, pas une ligne de code ni une variable d'environnement dans l'application. Le seul fichier modifié est celui de la configuration du collecteur. C'est la contrepartie du mode *pull* : là où une application instrumentée **pousse** ce qu'elle a décidé d'exposer, le collecteur va **chercher** ce qu'un composant tiers publie déjà.

La chaîne complète : receiver (scrape) → processors du pipeline `metrics` (`k8sattributes`, `memory_limiter`, `resourcedetection`, `resource`, `batch`) → exporter `otlphttp/prometheus` → Prometheus.
{{% /expand%}}

## Livrable

Dans Prometheus, onglet **Graph**, une courbe pour chacun de vos deux receivers :

```promql
system_cpu_load_average_15m
```

```promql
postgresql_rows{postgresql_table_name="public.reviews", state="live"}
```

La première prouve que `hostmetrics` tourne : c'est la charge du **nœud**, qu'aucune application de la démo ne publie. La seconde prouve que `postgresql` tourne, et elle a la bonne tête pour une capture — un escalier, une marche par avis posté à l'étape 6.
