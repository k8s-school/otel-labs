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
. ./scripts/env.sh                 # exporte PROM_PORT, ZPAGES_PORT, APP_PORT, PF_ADDR, PF_HOST
echo "$PROM_PORT $ZPAGES_PORT"     # 9090 et 55679
```

> Sur le serveur partagé, gardez `--address $PF_ADDR` dans les `port-forward` et `$PF_HOST` dans les URLs, comme dans les commandes ci-dessous : c'est ce qui donne à chaque participant sa propre adresse d'écoute. Sans lui, deux participants se disputent le même port et le second `port-forward` échoue.

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

> ⚠️ Helm sérialise le YAML **par ordre alphabétique** : les blocs apparaissent dans l'ordre `connectors`, `exporters`, `extensions`, `processors`, `receivers`, `service`, et non dans l'ordre du flux de données. Ne cherchez pas de logique dans cet ordre — c'est `service.pipelines`, tout en bas, qui décrit le flux réel.

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
cat /proc/1/root/conf/relay.yaml                      # le fichier réellement lu
cat /proc/1/environ | tr '\0' '\n' | grep MY_POD_IP   # les variables du collecteur
```

> `--profile=sysadmin` partage le namespace PID du pod cible : le processus `1` est le collecteur, et `/proc/1/root` donne accès à **son** système de fichiers depuis busybox. Vous lisez le fichier tel qu'il est monté — la preuve que ConfigMap et configuration effective coïncident.
>
> `MY_POD_IP` est injecté par le chart via la *downward API* ; c'est la variable que la configuration référence sous la forme `${env:MY_POD_IP}`. Le collecteur écoute donc sur **l'IP du pod**, pas sur `0.0.0.0`.

Sortez avec `exit`. Le conteneur éphémère ne redémarre pas, mais reste attachable tant que le pod vit (`kubectl attach ... -c <nom-généré> -i -t`) ; il disparaît avec le pod.

> 🚫 N'utilisez **pas** `kubectl debug --copy-to=...` ici. Cette variante crée un **pod indépendant**, copie du collecteur, qui réclame les mêmes `hostPort` (4317, 4318, 14250, 14268, 9411). Il reste `Pending` tant que le DaemonSet tourne, donc invisible — mais au prochain `helm upgrade` il s'empare des ports libérés et le nouveau pod du collecteur ne peut plus être planifié. Si vous en avez créé un : `kubectl delete pod <nom> -n otel-demo`.

#### c. Les sections qui comptent

Voici la configuration de la démo, **condensée et remise dans l'ordre logique** du flux de données (rappel : le fichier réel est trié alphabétiquement). Les clés sans valeur sont celles dont le détail a été coupé :

```yaml
# ---------- 1. RECEIVERS : par où la donnée ENTRE ----------
receivers:
  otlp:                                   # LE receiver standard, en push
    protocols:
      grpc:
        endpoint: ${env:MY_POD_IP}:4317   # <-- la cible de review-service (Lab 2)
      http:
        endpoint: ${env:MY_POD_IP}:4318   # utilisé par le frontend web de la boutique
        cors:
          allowed_origins: ["http://*", "https://*"]
  kafkametrics:                           # receiver « produit », en pull : LE MODÈLE À SUIVRE
    brokers: [kafka:9092]
    scrapers: [brokers, topics, consumers]
    collection_interval: 10s
  kubeletstats:                           # métriques des pods du nœud   (preset du chart)
  k8s_cluster:                            # état des objets Kubernetes   (preset du chart)
  prometheus:                             # auto-surveillance : le collecteur se scrape lui-même
  jaeger:                                 # protocoles historiques encore acceptés en entrée
  zipkin:

# ---------- 2. PROCESSORS : ce qui est appliqué ENTRE l'entrée et la sortie ----------
processors:
  memory_limiter:                         # garde-fou mémoire
    check_interval: 5s
    limit_percentage: 80
    spike_limit_percentage: 25
  k8sattributes:                          # enrichit avec namespace / pod / deployment...
  resourcedetection:
    detectors: [env, system]
  resource:                               # service.instance.id <- k8s.pod.uid
  transform:                              # OTTL : normalise les noms de spans du frontend
    error_mode: ignore
    trace_statements:
      - context: span
        statements:
          - set(span.attributes["http.route"], "/api/cart")
            where IsMatch(span.attributes["http.target"], "\\/api\\/cart")
  batch:                                  # regroupe juste avant l'export

# ---------- 3. CONNECTORS : la sortie d'un pipeline devient l'entrée d'un autre ----------
connectors:
  spanmetrics: {}                         # exporter du pipeline traces ET receiver du pipeline metrics

# ---------- 4. EXPORTERS : par où la donnée SORT ----------
exporters:
  otlp/jaeger:
    endpoint: jaeger:4317
  otlphttp/prometheus:
    endpoint: http://prometheus:9090/api/v1/otlp
  opensearch:
    http:
      endpoint: http://opensearch:9200
    logs_index: otel-logs
  debug: {}                               # écrit dans les logs du collecteur

# ---------- 5. EXTENSIONS : des services rendus HORS du flux de données ----------
extensions:
  health_check:                           # sonde HTTP de vivacité, utilisée par Kubernetes
    endpoint: ${env:MY_POD_IP}:13133
  k8s_leader_elector/k8s_cluster:         # un seul collecteur interroge l'API Kubernetes
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

Répondez maintenant, configuration sous les yeux :
* Par quel receiver les traces de `review-service` entrent-elles, et sur quelle **adresse** le collecteur écoute-t-il ?
* Vers quels backends partent les traces, les métriques, les logs ? Quel composant apparaît **à la fois** en exporter et en receiver ?
* Un receiver de « métriques produit » (mode *pull*) est déjà configuré — lequel ?
* Dans le pipeline `traces`, dans quel ordre les processors s'appliquent-ils, et pourquoi `batch` est-il en dernier ?

{{%expand "Réponse" %}}
* Les traces entrent par le receiver **`otlp`**, sur `${env:MY_POD_IP}:4317` (gRPC) et `:4318` (HTTP) — soit l'IP du pod, jointe par le service `otel-collector` que pointe `OTEL_EXPORTER_OTLP_ENDPOINT` au Lab 2. Les receivers `jaeger` et `zipkin` sont là pour les applications non OTLP.
* Pipelines : traces → **`otlp/jaeger`**, métriques → **`otlphttp/prometheus`**, logs → **`opensearch`** ; l'exporter `debug` est branché partout pour la mise au point. Le composant présent des deux côtés est le connector **`spanmetrics`** : *exporter* du pipeline `traces`, *receiver* du pipeline `metrics`. Il dérive des métriques de latence et de débit depuis les spans, sans instrumenter les applications.
* Le receiver **`kafkametrics`** interroge le broker Kafka toutes les 10 s. Sa structure est celle qu'il faudra écrire pour PostgreSQL : un endpoint, des identifiants, un `collection_interval`.
* Ordre : `k8sattributes` → `memory_limiter` → `resourcedetection` → `resource` → `transform` → `batch`. Enrichissement d'abord, regroupement en dernier.

Remarquez aussi le processor **`transform`** et ses instructions **OTTL** qui normalisent les noms de spans du frontend — un exemple réel du langage vu en cours — ainsi que `kubeletstats` et `k8s_cluster` : personne ne les a écrits, ce sont des **presets** du chart Helm qui les ont ajoutés.

> 📌 **`batch` en dernier, vraiment ?** Le [schéma officiel du collecteur](https://opentelemetry.io/docs/collector/img/otel-collector.svg) montre `Batch` **en tête** de la chaîne de processors : c'est une illustration générique de la notion de pipeline, pas une prescription d'ordre. La recommandation est donnée par le [README des processors](https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/README.md) : `memory_limiter` en premier, puis les processors qui **jettent** de la donnée (filtrage, échantillonnage), puis ceux qui l'**enrichissent**, et **`batch` en dernier** — inutile de dépenser du CPU à regrouper des données qui seront ensuite écartées ou modifiées. Les trois pipelines de la démo respectent cet ordre.
>
> Seule entorse : le preset `kubernetesAttributes` du chart insère `k8sattributes` **avant** `memory_limiter`, alors que la recommandation le place après. Sans conséquence ici, ce processor n'accumulant pas de données — mais c'est exactement le genre de détail que la lecture d'une configuration réelle apprend à repérer.
{{% /expand%}}

### 2. Constater ce qui manque dans Prometheus

```bash
kubectl port-forward -n otel-demo --address $PF_ADDR svc/prometheus $PROM_PORT:9090 &
```

Ouvrez `http://$PF_HOST:$PROM_PORT` (soit `http://localhost:9090` sur un poste individuel) et cherchez dans l'autocomplétion :

| Recherche | Résultat | Pourquoi |
| --- | --- | --- |
| `kafka_` | des métriques ✔ | le receiver `kafkametrics` du collecteur les collecte |
| `system_` | des métriques ✔ — **mais pas celles du nœud** | voir le piège ci-dessous |
| `system_cpu_load_average_15m` | rien ✘ | seul le scraper `load` de `hostmetrics` produit la charge de la machine |
| `postgresql_` | rien ✘ | aucun receiver n'interroge la base |

> ⚠️ **Le piège du préfixe.** `system_*` n'est pas vide, alors que `hostmetrics` n'est pas configuré : ces séries sont émises par les applications Python de la boutique, qui mesurent **leur propre processus**. Elles ne disent rien de la machine. Le nom d'une métrique ne suffit donc pas — regardez qui l'envoie :
>
> ```promql
> count by (job) (system_cpu_time_seconds_total)
> ```
>
> Vous n'obtenez que des applications (`otel-demo/load-generator`...) : dans Prometheus, `job` identifie le service émetteur — c'est `service.namespace/service.name`, les attributs que l'application déclare. C'est pourquoi le critère du lab est `system_cpu_load_average_15m` : la charge d'une machine, aucune application ne peut la produire.

### 3. Écrire le fichier de values qui ajoute les deux receivers

Créez `manifests/30-otel-collector-values.yaml`. Il doit ajouter au collecteur :
* un receiver **`hostmetrics`** (scrapers `cpu`, `memory`, `load`, `disk`, `network`) ;
* un receiver **`postgresql`** pointé sur la base de la boutique (service `postgresql:5432`, user `root`, mot de passe `otel`) — celle-là même qu'utilise votre `review-service` ;
* l'extension **`zpages`** (pages de debug du collecteur) ;
* et il doit **brancher les deux receivers dans le pipeline `metrics`**.

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
kubectl port-forward -n otel-demo --address $PF_ADDR daemonset/otel-collector-agent $ZPAGES_PORT:55679 &
```

Ouvrez `http://$PF_HOST:$ZPAGES_PORT/debug/pipelinez` : vos deux receivers doivent apparaître dans le pipeline `metrics`.

> zPages affiche les composants **réellement chargés** par le collecteur, là où la ConfigMap ne montre que ce qu'on lui a demandé. Le pipeline `metrics` liste donc aussi `kubeletstats` et `k8s_cluster`, ajoutés par les presets du chart — c'est normal, vous ne les avez pas perdus.

### 6. Vérifier dans Prometheus

Reprenez le tableau de l'étape 2, avec les mêmes recherches :

| Recherche | Avant | Après |
| --- | --- | --- |
| `system_cpu_load_average_15m` | rien ✘ | présent ✔ — la charge du **nœud** |
| `postgresql_` | rien ✘ | présent ✔ |
| `count by (job) (system_cpu_time_seconds_total)` | uniquement des applications | une série de plus, émise par le **collecteur** |

Générez ensuite quelques avis avec `curl` (cf. Lab 2) et observez `postgresql_commits_total` ou `postgresql_operations_total` évoluer.

{{%expand "Réponse" %}}
Les métriques arrivent avec les conventions sémantiques OTel traduites en noms Prometheus :
* `system_cpu_load_average_1m` / `_5m` / `_15m`, et les séries déjà présentes `system_cpu_time_seconds_total`, `system_memory_usage_bytes`, `system_network_io_bytes_total`...
* `postgresql_backends`, `postgresql_commits_total`, `postgresql_operations_total`, `postgresql_rows`, `postgresql_blocks_read_total`, `postgresql_db_size_bytes`, `postgresql_table_size_bytes`...

Côté système, c'est bien `system_cpu_load_average_15m` qui prouve que votre receiver fonctionne : les autres `system_*` existaient déjà avant l'étape 4 (cf. le piège de l'étape 2).

La chaîne complète : receiver (scrape) → processors du pipeline `metrics` (`k8sattributes`, `memory_limiter`, `resourcedetection`, `resource`, `batch`) → exporter `otlphttp/prometheus` → Prometheus. Aucune application n'a été modifiée.
{{% /expand%}}

## Livrable

Un graphe Prometheus montrant une métrique système **et** une métrique PostgreSQL collectées par votre configuration.
