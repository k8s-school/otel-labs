---
title: 'Lab 2 — Instrumentation zero-code d''un micro-service Java'
date: 2026-07-06T11:40:00+02:00
draft: false
weight: 20
tags: ["OpenTelemetry", "Java", "agent", "Spring Boot"]
---

L'équipe Java a livré **`review-service`**, un micro-service Spring Boot de gestion des avis produits (API REST + PostgreSQL). Il n'émet **aucune télémétrie**. Dans ce lab, vous allez le rendre observable **sans toucher à son code**, de deux manières :

* **Partie 1** : avec l'**agent Java** OpenTelemetry (`-javaagent`) ;
* **Partie 2** : avec le **Spring Boot Starter** OpenTelemetry (dépendance Maven).

Le code du service est dans `apps/review-service/`. Le script `./scripts/deploy.sh` fait tout le cycle : `docker build` → `kind load` → `kubectl apply` → attente du rollout. Pas de registry d'images : l'image est chargée directement dans le cluster Kind.

> ⚠️ Chaque build produit un **tag d'image unique** (`<profil>-<user>-<horodatage>`) : Kind ne re-télécharge jamais un tag qu'il connaît déjà, un tag fixe comme `latest` ne serait donc **jamais mis à jour**.

## Prérequis

* Lab 1 terminé : la stack tourne dans le namespace `otel-demo`.
* Le port-forward des UIs actif (`./scripts/open-ui.sh` dans un terminal séparé).

## Étapes

### Partie 1 — L'agent Java

1.  **Déployer le service tel que livré (non instrumenté) :**

```bash
./scripts/deploy.sh
```

> Le script construit l'image, la charge dans Kind et applique `apps/review-service/k8s/review-service.yaml` dans le namespace `otel-demo`.

2.  **Générer du trafic vers l'API :**

```bash
kubectl port-forward -n otel-demo svc/review-service 8090:8080 &
curl http://localhost:8090/api/reviews
curl http://localhost:8090/api/reviews/product/OLJCESPC7Z
curl -X POST http://localhost:8090/api/reviews \
  -H "Content-Type: application/json" \
  -d '{"productId": "OLJCESPC7Z", "rating": 5, "comment": "Superbe lunette !", "userEmail": "jean.dupont@example.com", "userName": "Jean Dupont"}'
```

3.  **Chercher `review-service` dans Jaeger.** Que constatez-vous ?

{{%expand "Réponse" %}}
Rien. Le service répond, il écrit en base... mais il est **invisible** : aucune trace, car aucune instrumentation n'est active. C'est l'état de la plupart des applications avant OpenTelemetry.
{{% /expand%}}

4.  **Activer l'agent Java.**

L'image contient déjà l'agent (`/otel/opentelemetry-javaagent.jar`), téléchargé au build — regardez le `Dockerfile`. Il ne manque que le flag JVM. Éditez `apps/review-service/k8s/review-service.yaml` et décommentez :

```yaml
            - name: JAVA_TOOL_OPTIONS
              value: "-javaagent:/otel/opentelemetry-javaagent.jar"
```

Observez aussi les variables `OTEL_*` déjà présentes dans le manifest. À quoi sert chacune ?

{{%expand "Réponse" %}}
* `OTEL_SERVICE_NAME=review-service` — le nom sous lequel le service apparaîtra dans Jaeger/Grafana (convention sémantique `service.name`) ;
* `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317` — où envoyer la télémétrie : le collecteur de la démo, en OTLP ;
* `OTEL_EXPORTER_OTLP_PROTOCOL=grpc` — variante gRPC du protocole OTLP (port 4317 ; le port 4318 sert la variante HTTP) ;
* `OTEL_RESOURCE_ATTRIBUTES=service.namespace=otel-demo` — attributs de ressource additionnels.

`JAVA_TOOL_OPTIONS` est lue par la JVM au démarrage : c'est le moyen standard d'injecter `-javaagent` sans modifier ni le code ni la commande de lancement.
{{% /expand%}}

5.  **Redéployer et re-générer du trafic :**

```bash
./scripts/deploy.sh
# relancer le port-forward (le pod a changé)
kubectl port-forward -n otel-demo svc/review-service 8090:8080 &
curl http://localhost:8090/api/reviews
```

6.  **Retrouver la trace dans Jaeger.**

Cherchez le service `review-service`. Ouvrez une trace de `GET /api/reviews`. Quels spans l'agent a-t-il créés automatiquement, sans une ligne de code ?

{{%expand "Réponse" %}}
Typiquement deux niveaux :
* un span **serveur HTTP** `GET /api/reviews` (instrumentation de Tomcat/Spring MVC) avec les attributs `http.request.method`, `http.route`, `http.response.status_code`... ;
* un ou plusieurs spans **SQL** enfants (instrumentation JDBC) avec `db.system=postgresql` et la requête `SELECT` exécutée.

L'agent instrumente **par manipulation de bytecode** les bibliothèques qu'il connaît (Tomcat, Spring, JDBC, Kafka, HTTP clients... plus de 100 frameworks).

Comparez avec le service `ad` de la démo : lui aussi est un service Java instrumenté par l'agent — vous y verrez la même structure de spans.
{{% /expand%}}

### Partie 2 — Le Spring Boot Starter

7.  **Reconstruire le service avec le Starter :**

Le `pom.xml` contient un profil Maven `starter` qui ajoute la dépendance `opentelemetry-spring-boot-starter` — regardez-le. **Re-commentez d'abord `JAVA_TOOL_OPTIONS`** dans le manifest (l'agent et le starter ne doivent pas cohabiter), puis :

```bash
./scripts/deploy.sh -p starter
```

8.  **Générer du trafic et comparer les traces.**

Reprenez les mêmes `curl` qu'à l'étape 2, puis comparez dans Jaeger une trace `GET /api/reviews` produite par le **starter** avec celle produite par l'**agent**.

{{%expand "Réponse" %}}
Les deux produisent le span serveur HTTP et les spans JDBC. Différences notables :

| | Agent Java | Spring Boot Starter |
|---|---|---|
| Mise en œuvre | flag JVM, aucun changement de build | dépendance Maven, rebuild nécessaire |
| Couverture | ~toutes les libs Java connues (bytecode) | instrumentations Spring + libs principales |
| Démarrage | plus lent (instrumentation au chargement) | plus rapide, compatible GraalVM native |
| Granularité | très détaillée | plus ciblée Spring |

**Quand préférer le starter ?** Images natives (GraalVM), maîtrise fine des dépendances, ou politique interdisant les agents JVM. **Quand préférer l'agent ?** Instrumenter un parc existant sans toucher aux builds.
{{% /expand%}}

## Livrable

Deux traces du même endpoint `GET /api/reviews` dans Jaeger : une produite par l'agent, une par le starter.
