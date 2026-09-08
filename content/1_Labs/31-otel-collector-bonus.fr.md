---
title: 'Lab 3 bonus — La configuration du collecteur, section par section'
date: 2026-09-08T20:45:00+02:00
draft: false
weight: 31
tags: ["OpenTelemetry", "collecteur", "pipelines", "YAML"]
---

Page de lecture : rien à construire, rien à déployer. Elle ouvre en grand la configuration que le [Lab 3]({{% relref "30-otel-collector" %}}) vous a fait afficher, et la parcourt section par section — receivers, processors, connectors, exporters, extensions, `service` — puis pose cinq questions dont les réponses sont juste en dessous.

À lire avant le Lab 3 si vous avez le temps, après si la séance presse : l'étape 3 du Lab 3 vous fera écrire dans ce même fichier, et tout ce qui suit sert à savoir où.

## La configuration, remise dans l'ordre du flux

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
          # le JavaScript de la boutique émet ses traces DEPUIS le navigateur du
          # client : sans cette autorisation, c'est le navigateur lui-même qui
          # bloquerait l'envoi (voir l'encadré sous la question a)
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
  # les spans et mesure leur durée, puis en publie des métriques que vous tracerez au
  # Lab 4. `{}` = configuration par défaut, d'où le préfixe traces_span_metrics_ des
  # noms produits (voir la réponse ci-dessous).
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

> 🌐 **Le bloc `cors` du port 4318 n'existe que pour un émetteur : le navigateur.** La boutique est instrumentée côté client — c'est ce qui produit les spans `frontend-web` en tête de vos traces de checkout. Ces spans-là ne partent pas d'un pod : ils partent du **JavaScript exécuté dans le navigateur du client**, qui poste directement en OTLP/HTTP.
>
> Or un navigateur s'interdit d'appeler une autre origine que celle de la page (*same-origin policy*). Avant le vrai `POST`, il envoie une requête `OPTIONS` — le *preflight* — et attend un en-tête `Access-Control-Allow-Origin` en réponse. S'il ne l'obtient pas, **c'est lui qui annule l'envoi** : le collecteur n'a rien refusé, la trace n'est simplement jamais partie, et l'erreur ne se lit que dans la console du navigateur.
>
> `allowed_origins: ["http://*", "https://*"]` répond donc « j'accepte les spans de n'importe quelle page ». Deux conséquences : vos services (`review-service`, `checkout`, `ad`) ne sont **pas** concernés — le CORS est une règle que les navigateurs s'appliquent à eux-mêmes, un `curl` sur le même port passe sans rien demander ; et en production on n'écrit pas `*`, mais les origines réelles du frontend, sans quoi n'importe quel site peut faire écrire dans votre plateforme d'observabilité par le navigateur de ses visiteurs.
{{% /expand%}}

**b. Vers quels backends partent les traces, les métriques, les logs ? Quel composant apparaît *à la fois* en exporter et en receiver ?**

{{%expand "Réponse" %}}
Traces → **`otlp/jaeger`**, métriques → **`otlphttp/prometheus`**, logs → **`opensearch`** ; l'exporter `debug` est branché partout pour la mise au point.

Le composant présent des deux côtés est le connector **`spanmetrics`** : *exporter* du pipeline `traces`, *receiver* du pipeline `metrics`. Il fait donc le **pont entre deux pipelines**, et c'est tout l'intérêt d'un connector :

* **en sortie du pipeline `traces`**, il reçoit les spans comme n'importe quel exporter — mais il ne les envoie nulle part ;
* il les **compte** par service et par opération, et **mesure leur durée** ;
* **à l'entrée du pipeline `metrics`**, il injecte le résultat de ce comptage : deux métriques, le débit et la latence (sous forme d'histogramme).

Ce ne sont donc pas les spans eux-mêmes qui repartent dans le pipeline `metrics` — ils continuent leur route vers Jaeger — mais des **chiffres calculés à partir d'eux**. Résultat : tout service tracé obtient gratuitement ses métriques de débit et de latence, sans une ligne d'instrumentation de plus — vous les tracerez dans Grafana au Lab 4.

Leurs noms dans Prometheus sont `traces_span_metrics_calls_total` et `traces_span_metrics_duration_milliseconds_bucket` / `_count` / `_sum`. Le préfixe surprend, et il est instructif : `spanmetrics: {}` signifie « configuration par défaut », or ce défaut comprend un **namespace**, `traces.span.metrics`, que le connector colle devant chaque nom. Cherchez `calls_total` seul dans Prometheus et vous ne trouverez rien — c'est le genre de détail qu'aucune documentation ne remplace : listez les noms réels avant d'écrire une requête.
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

> ⚠️ **Quand `memory_limiter` mord, ça se voit dans les logs de vos applications — jamais dans Grafana.** Ses deux réglages se lisent ensemble : `limit_percentage: 80` place le seuil **dur** à 80 % de la mémoire du conteneur, et `spike_limit_percentage: 25` avance le seuil **souple** 25 points plus bas. Le refus commence donc dès **55 %**. Sur un collecteur limité à 200 Mi — la valeur du chart, avant que les values de la formation ne la relèvent — cela faisait 110 Mi, et l'agent s'y cognait une quarantaine de fois par heure, en continu.
>
> Côté application émettrice, le refus se lit ainsi :
>
> ```text
> ERROR io.opentelemetry.exporter.internal.grpc.GrpcExporter - Failed to export spans.
> Server is UNAVAILABLE. ... data refused due to high memory usage
> ```
>
> Le SDK retente, puis renonce : **la télémétrie est perdue**. Et c'est là le piège — le collecteur ne redémarre pas, aucune alerte ne se déclenche, et Grafana se contente d'afficher des courbes un peu creuses. Un panel incomplet, une trace amputée de son saut vers le service suivant, un log jamais arrivé dans OpenSearch : rien ne distingue cela d'une manipulation ratée. D'où le réflexe à prendre : **quand une donnée manque, lisez d'abord les logs de l'application qui l'émet** (`kubectl logs -n otel-demo deployment/<service>`) avant de soupçonner votre propre configuration.
{{% /expand%}}

Deux détails à ne pas manquer en refermant cette configuration : le processor **`transform`** et ses instructions **OTTL** qui normalisent les noms de spans du frontend — un exemple réel du langage vu en cours — ainsi que `kubeletstats` et `k8s_cluster` : personne ne les a écrits, ce sont des **presets** du chart Helm qui les ont ajoutés.
