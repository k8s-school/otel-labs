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
* **Les variables de la formation chargées dans votre shell.** Les commandes ci-dessous accèdent au service **en direct** (pas via le frontend-proxy), sur le port local `$APP_PORT`. Sourcez `scripts/env.sh` une fois en début de session :

```bash
. ./scripts/env.sh   # exporte APP_PORT, UI_PORT, PROM_PORT... et PF_ADDR / PF_HOST
echo "$APP_PORT"     # 8090, pour tout le monde
```

> `$PF_ADDR` est l'adresse sur laquelle vos `port-forward` écoutent, `$PF_HOST` le nom par lequel vous les joignez. Sur un poste individuel : `127.0.0.1` et `localhost`. Sur le serveur partagé, votre compte a les siens (`student3` → `127.0.0.3`, alias `localhost3`), ce qui permet à tous les participants d'utiliser les mêmes ports sans se marcher dessus. Gardez donc `$PF_ADDR` / `$PF_HOST` dans les commandes plutôt que `localhost` en dur.

## Étapes

### Partie 1 — L'agent Java

1.  **Déployer le service tel que livré (non instrumenté) :**

```bash
./scripts/deploy.sh
```

> Le script construit l'image, la charge dans Kind et applique `apps/review-service/k8s/review-service.yaml` dans le namespace `otel-demo`.

2.  **Générer du trafic vers l'API :**

```bash
kubectl port-forward -n otel-demo --address $PF_ADDR svc/review-service $APP_PORT:8080 &
curl http://$PF_HOST:$APP_PORT/api/reviews
curl http://$PF_HOST:$APP_PORT/api/reviews/product/OLJCESPC7Z
curl -X POST http://$PF_HOST:$APP_PORT/api/reviews \
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
* `OTEL_RESOURCE_ATTRIBUTES=service.namespace=otel-demo` — attributs de ressource additionnels attachés à *toute* la télémétrie. `service.namespace` **regroupe logiquement** les services : couplé à `service.name`, il range `review-service` avec les autres services de la démo dans Jaeger/Grafana.

> ⚠️ **Pourquoi le fixer à la main, ce n'est pas déductible ?** Attention à ne pas confondre `service.namespace` (OTel) et `k8s.namespace.name` (Kubernetes) :
> * l'**agent/SDK ne voit que le processus**, pas Kubernetes — il ignore le namespace K8s du pod, donc il ne peut rien déduire seul ;
> * ce qui *peut* être injecté automatiquement, c'est `k8s.namespace.name` (via le `k8sattributes` processor du collecteur, l'OTel Operator, ou la Downward API `fieldRef: metadata.namespace`). Mais c'est un attribut d'**infrastructure** ;
> * `service.namespace` est un attribut **logique / métier** : un *choix* de regroupement, pas un fait de l'infra. Ici il vaut `otel-demo` par coïncidence (même nom que le namespace K8s), mais rien ne les oblige à coïncider.
>
> D'où l'approche explicite d'une ligne dans le manifest — sans dépendre du collecteur ni de l'Operator.

`JAVA_TOOL_OPTIONS` est lue par la JVM au démarrage : c'est le moyen standard d'injecter `-javaagent` sans modifier ni le code ni la commande de lancement.
{{% /expand%}}

5.  **Redéployer et re-générer du trafic :**

```bash
./scripts/deploy.sh
# relancer le port-forward (le pod a changé)
kubectl port-forward -n otel-demo --address $PF_ADDR svc/review-service $APP_PORT:8080 &
curl http://$PF_HOST:$APP_PORT/api/reviews
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

Contrairement à l'agent (un simple flag JVM au *runtime*), le Starter est une **dépendance compilée dans l'application** : il faut donc **rebâtir l'image**. Avant de lancer la commande, suivez la chaîne d'activation — de l'option `deploy.sh` jusqu'au `pom.xml`.

7.  **Comprendre comment le profil `starter` s'active.** Ouvrez `scripts/deploy.sh`, `apps/review-service/Dockerfile` et `apps/review-service/pom.xml`, puis répondez :

    a. Dans `pom.xml`, qu'ajoute le profil Maven `starter` que le profil `default` n'a pas ?

    b. Dans le `Dockerfile`, comment le profil est-il choisi au moment du build ? Quelle commande Maven le consomme ?

    c. Dans `deploy.sh`, comment l'option `-p starter` parvient-elle jusqu'au `Dockerfile` ?

{{%expand "Réponse" %}}
La chaîne d'activation, du plus haut au plus bas niveau :

```text
./scripts/deploy.sh -p starter
 └─ docker build --build-arg MAVEN_PROFILE=starter ...
     └─ Dockerfile : ARG MAVEN_PROFILE → RUN mvn -P ${MAVEN_PROFILE} -DskipTests package
         └─ pom.xml : le profil <id>starter</id> ajoute la dépendance
                      opentelemetry-spring-boot-starter (+ le BOM qui fixe sa version)
```

* **`pom.xml`** — le profil `default` (`activeByDefault`) n'ajoute **rien** : l'appli n'a que l'API OTel, qui reste *no-op* sans SDK. Le profil `starter` ajoute la dépendance `opentelemetry-spring-boot-starter` et importe le `opentelemetry-instrumentation-bom` (qui aligne les versions OTel). C'est cette dépendance qui embarque le **SDK + les auto-configurations Spring**.
* **`Dockerfile`** — `ARG MAVEN_PROFILE=default` déclare la variable de build, consommée à l'étape de compilation : `RUN mvn -P ${MAVEN_PROFILE} -DskipTests package`. Changer le profil change donc le `.jar` produit → **rebuild obligatoire** (l'agent, lui, ne touchait pas au build).
* **`deploy.sh`** — `-p starter` positionne `PROFILE=starter`, passé à Docker via `docker build --build-arg MAVEN_PROFILE=starter`. Cette même valeur sert de **tag d'image** (`starter-<user>-<horodatage>`), pour que Kind recharge bien la nouvelle image.

> À retenir : l'agent est **toujours** présent dans l'image mais **inactif** sans `JAVA_TOOL_OPTIONS` ; le Starter, lui, est actif **dès qu'il est compilé**. D'où la règle : jamais les deux ensemble.
{{% /expand%}}

8.  **Rebâtir avec le Starter.** **Re-commentez d'abord `JAVA_TOOL_OPTIONS`** dans le manifest (sinon agent + starter = deux SDK → l'application ne démarre pas), puis :

```bash
./scripts/deploy.sh -p starter
```

Dans les logs de build, repérez la ligne Maven qui confirme le profil actif, puis re-générez du trafic (mêmes `curl` qu'à l'étape 2).

9.  **Comparer les traces.**

Comparez dans Jaeger une trace `GET /api/reviews` produite par le **starter** avec celle produite par l'**agent** (partie 1).

{{%expand "Réponse" %}}
Les deux produisent le span serveur HTTP et les spans JDBC — mais par des **mécanismes opposés**, et c'est ce qui explique tout le reste :

* **Agent** = un programme **externe** attaché à la JVM (`-javaagent`) qui **réécrit le bytecode** des bibliothèques connues *au chargement*, sans que l'appli ni son build ne le sachent.
* **Starter** = une **dépendance compilée dans** l'appli, qui se branche sur les **points d'extension de Spring** (auto-configuration) — pas de manipulation de bytecode.

Sur ce lab, le cas courant (Spring MVC + JDBC) est couvert des deux côtés, d'où des traces quasi identiques. La différence n'apparaît qu'**aux extrémités** (libs exotiques, drivers hors Spring) et sur les propriétés opérationnelles :

| | Agent Java | Spring Boot Starter |
|---|---|---|
| Mise en œuvre | flag JVM, aucun changement de build | dépendance Maven, rebuild nécessaire |
| Couverture | ~toutes les libs Java connues (bytecode) | instrumentations Spring + libs principales |
| Démarrage | plus lent (bytecode réécrit au chargement) | plus rapide, compatible GraalVM native |
| Granularité | très détaillée | plus ciblée Spring |

> **GraalVM native** = compilation *ahead-of-time* de l'appli en exécutable natif (démarrage en millisecondes, faible mémoire). Comme le binaire est figé au build, **aucune réécriture de bytecode n'est possible au runtime** → l'agent ne marche pas, mais le Starter (déjà compilé dedans) oui.
>
> ℹ️ **GraalVM n'est pas utilisé dans ce lab** : `review-service` tourne sur une JVM classique (Temurin 21, un simple `.jar`). C'est un *argument* en faveur du Starter pour la prod native, pas quelque chose à activer ici.

**Quand préférer le starter ?** Images natives (GraalVM), maîtrise fine des dépendances, ou politique interdisant les agents JVM. **Quand préférer l'agent ?** Instrumenter un parc existant sans toucher aux builds.
{{% /expand%}}

## Livrable

Deux traces du même endpoint `GET /api/reviews` dans Jaeger : une produite par l'agent, une par le starter.
