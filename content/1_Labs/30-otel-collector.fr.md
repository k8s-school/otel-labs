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

## Étapes

1.  **Lire la configuration actuelle du collecteur :**

```bash
kubectl get configmap otel-collector-agent -n otel-demo -o yaml | less
```

> Le chart Helm génère cette ConfigMap ; le collecteur (un DaemonSet) la monte au démarrage.

Identifiez les 4 blocs principaux : `receivers`, `processors`, `exporters` et `service.pipelines`. Répondez :
* Par quel receiver les traces de `review-service` entrent-elles ?
* Vers quels backends partent les traces, les métriques, les logs ?
* Un receiver de « métriques produit » est déjà configuré — lequel ?

{{%expand "Réponse" %}}
* Les traces entrent par le receiver **`otlp`** (gRPC 4317 / HTTP 4318) — c'est l'endpoint que pointe `OTEL_EXPORTER_OTLP_ENDPOINT` du Lab 2.
* Pipelines : traces → **`otlp/jaeger`**, métriques → **`otlphttp/prometheus`**, logs → **`opensearch`**. Le pipeline traces alimente aussi le connector **`spanmetrics`** (des métriques dérivées des spans).
* Le receiver **`kafkametrics`** interroge déjà le broker Kafka de la boutique : c'est le modèle à suivre pour PostgreSQL.

Remarquez aussi le processor **`transform`** et ses instructions **OTTL** qui normalisent les noms de spans du frontend — un exemple réel du langage vu en cours.
{{% /expand%}}

2.  **Constater ce qui manque dans Prometheus :**

```bash
kubectl port-forward -n otel-demo svc/prometheus 9090:9090 &
```

Ouvrez [http://localhost:9090](http://localhost:9090) et cherchez dans l'autocomplétion :
* `kafka_` ... des métriques existent ✔
* `system_` ... rien ✘
* `postgresql_` ... rien ✘

3.  **Écrire le fichier de values qui ajoute les deux receivers.**

Créez `manifests/values-lab3.yaml`. Il doit ajouter au collecteur :
* un receiver **`hostmetrics`** (scrapers `cpu`, `memory`, `load`, `disk`, `network`) ;
* un receiver **`postgresql`** pointé sur la base de la boutique (service `postgresql:5432`, user `root`, mot de passe `otel`) — celle-là même qu'utilise votre `review-service` ;
* l'extension **`zpages`** (pages de debug du collecteur) ;
* et il doit **brancher les deux receivers dans le pipeline `metrics`**.

> ⚠️ En YAML Helm, une liste redéfinie **remplace** la liste d'origine : le pipeline `metrics` doit re-lister *tous* ses receivers, pas seulement les nouveaux.

{{%expand "Réponse" %}}
Le fichier de référence est [`30-otel-collector-values.yaml`](../30-otel-collector-values.yaml) :

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

4.  **Appliquer la nouvelle configuration :**

```bash
helm upgrade otel-demo open-telemetry/opentelemetry-demo \
  --version 0.40.9 -n otel-demo \
  -f manifests/values-training.yaml \
  -f manifests/values-lab3.yaml

kubectl rollout status daemonset/otel-collector -n otel-demo
```

> `helm upgrade` régénère la ConfigMap et redémarre le collecteur. Les values s'empilent : le fichier de la formation, puis le vôtre.

5.  **Observer le pipeline dans zPages :**

```bash
kubectl port-forward -n otel-demo daemonset/otel-collector 55679:55679 &
```

Ouvrez [http://localhost:55679/debug/pipelinez](http://localhost:55679/debug/pipelinez) : vos deux receivers doivent apparaître dans le pipeline `metrics`.

6.  **Vérifier dans Prometheus :**

Recherchez à nouveau `system_` et `postgresql_`. Générez quelques avis avec `curl` (cf. Lab 2) et observez `postgresql_tup_inserted` ou `postgresql_blks_hit` évoluer.

{{%expand "Réponse" %}}
Les métriques arrivent avec les conventions sémantiques OTel traduites en noms Prometheus :
* `system_cpu_time_seconds_total`, `system_memory_usage_bytes`, `system_network_io_bytes_total`...
* `postgresql_blks_hit_total`, `postgresql_tup_inserted_total`, `postgresql_backends`...

La chaîne complète : receiver (scrape) → processors communs (memory_limiter, batch...) → exporter `otlphttp/prometheus` → Prometheus. Aucune application n'a été modifiée.
{{% /expand%}}

## Livrable

Un graphe Prometheus montrant une métrique système **et** une métrique PostgreSQL collectées par votre configuration.
