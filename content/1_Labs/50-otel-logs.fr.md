---
title: 'Lab 5 — Logs structurées et corrélées'
date: 2026-07-06T09:50:00+02:00
draft: false
weight: 50
tags: ["OpenTelemetry", "logs", "Logback", "OpenSearch"]
---

`review-service` écrit ses logs avec **SLF4J/Logback**, comme la plupart des applications Java. Dans ce lab, vous suivez le trajet complet d'un log : Logback → appender OpenTelemetry (injecté par l'agent) → OTLP → collecteur → **OpenSearch** — et surtout, vous exploitez la **corrélation log ↔ trace**.

## Prérequis

* Labs 1 à 3 terminés.
* Le port-forward des UIs actif (`./scripts/open-ui.sh`).
* Les variables de la formation chargées dans votre shell : `. ./scripts/env.sh`. Elles donnent le port du review-service (`$APP_PORT`, accès **direct** au service, pas via le frontend-proxy) ainsi que `$PF_ADDR` et `$PF_HOST`, l'adresse sur laquelle vos `port-forward` écoutent.

## Étapes

1.  **Les logs « à l'ancienne » :**

```bash
kubectl logs -n otel-demo deployment/review-service --tail=20
```

> `kubectl logs` lit la sortie console du conteneur : du texte brut, sans contexte, service par service. Impossible de croiser avec une trace.

2.  **Revenir à la version « agent Java » :**

Le Lab 2 s'est terminé avec le build **starter** déployé. Notez-le : lui aussi capture les logs, vous en verriez donc dans Grafana sans rien changer. On revient à l'agent parce que c'est **l'approche que suivent les labs suivants** — le Lab 6 active son pont Micrometer (`OTEL_INSTRUMENTATION_MICROMETER_ENABLED`), une option qui n'existe que chez lui.

Agent et starter sont deux alternatives : les laisser ensemble installerait deux SDK dans la même JVM. On redéploie donc l'image par défaut — celle qui ne contient pas le starter — puis on active l'agent :

```bash
./scripts/deploy.sh
kubectl set env -n otel-demo deployment/review-service \
  JAVA_TOOL_OPTIONS="-javaagent:/otel/opentelemetry-javaagent.jar"
kubectl rollout status -n otel-demo deployment/review-service
```

{{%expand "Comment l'agent capture-t-il les logs ?" %}}
L'agent détecte Logback et y **injecte l'équivalent de l'appender OpenTelemetry** (`io.opentelemetry.instrumentation:opentelemetry-logback-appender`). Chaque événement Logback devient un **LogRecord** OTel : timestamp, sévérité, body, attributs... et surtout le **`trace_id`/`span_id` courant** si le log est émis pendant une requête tracée.

Le **Spring Boot Starter** de la partie 2 du Lab 2 fait la même chose, autrement : l'appender est une dépendance compilée dans l'application, qu'il branche sur Logback au démarrage. D'où le constat de l'étape 2 — les deux approches produisent des logs corrélés, et le Lab 4 les affiche indifféremment.

Et sans ni l'un ni l'autre ? On déclare l'appender à la main dans `logback.xml` et on construit le SDK (`LoggerProvider`) — c'est l'approche « SDK » vue en cours.
{{% /expand%}}

3.  **Générer des logs corrélés :**

```bash
. ./scripts/env.sh   # si ce n'est pas déjà fait dans ce terminal
kubectl port-forward -n otel-demo --address $PF_ADDR svc/review-service $APP_PORT:8080 &
curl http://$PF_HOST:$APP_PORT/api/reviews
curl -X POST http://$PF_HOST:$APP_PORT/api/reviews \
  -H "Content-Type: application/json" \
  -d '{"productId": "OLJCESPC7Z", "rating": 4, "comment": "Très bon rapport qualité/prix", "userEmail": "marie.curie@example.com", "userName": "Marie Curie"}'
```

4.  **Retrouver ces logs dans Grafana :**

*Explore* → datasource **OpenSearch** → requête Lucene :

```text
resource.service.name:"review-service"
```

Dépliez le log `Creating review for product...`. Quels champs OTel voyez-vous autour du message ?

{{%expand "Réponse" %}}
Le LogRecord est **structuré** :
* `body` : le message ;
* `severity.text` / `severity.number` : le niveau (INFO...) ;
* `resource.service.name`, `k8s.pod.name`... : la **ressource** (qui a émis) ;
* `instrumentationScope.name` : le logger (`fr.k8sschool.reviews.ReviewController`) ;
* **`traceId` et `spanId`** : la corrélation avec la trace en cours.

Au passage : le message contient l'**email du client** en clair... Gardez ça en tête pour le Lab 8 (RGPD).
{{% /expand%}}

5.  **Du log à la trace en un clic :**

Toujours dans le log déplié, suivez le lien du champ `traceId` (bouton *View in Jaeger* configuré dans la datasource). Vous atterrissez sur la trace exacte qui a produit ce log : `POST /api/reviews` avec ses spans HTTP, catalogue et SQL.

6.  **Comprendre le trajet côté collecteur :**

```bash
kubectl get configmap otel-collector-agent -n otel-demo -o yaml | grep -A8 "logs:"
```

{{%expand "Réponse" %}}
Le pipeline `logs` de la démo :

```yaml
logs:
  receivers: [otlp]
  processors: [memory_limiter, resourcedetection, resource, batch]
  exporters: [opensearch, debug]
```

Les LogRecords arrivent en **OTLP** (poussés par l'agent), sont enrichis, puis indexés dans **OpenSearch** (index `otel-logs-*`) — celui que requête la datasource Grafana.
{{% /expand%}}

7.  **Bonus — receiver `filelog` :** le collecteur sait aussi **lire des fichiers de logs** (applis legacy, pods non instrumentés). Sur le modèle du Lab 3, ajoutez à la config du collecteur un receiver `filelog` pointé sur `/var/log/pods/*/*/*.log` et branchez-le au pipeline `logs` (le chart monte déjà les volumes en mode DaemonSet via le preset `logsCollection`). À discuter avec le formateur selon le temps restant.

## Livrable

Une capture « log → trace » : le log `Creating review...` déplié dans Grafana avec son `traceId`, et la trace Jaeger correspondante ouverte.
