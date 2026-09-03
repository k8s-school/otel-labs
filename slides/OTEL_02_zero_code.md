---
marp: true
theme: custom-theme
paginate: true
backgroundColor: #ffffff
---

# Formation OpenTelemetry

## Chapitre 2 — Instrumentation zero-code

<img src="images/logo.svg" alt="K8s School Logo" width="50%">

---

## Le problème

- Votre parc applicatif existe **déjà** : des dizaines de services non instrumentés
- Modifier le code de chacun ? Coûteux, lent, risqué
- **Zero-code** : obtenir traces, métriques et logs **sans modifier le code source**
- Deux approches en Java :
  - l'**agent Java** OpenTelemetry
  - le **Spring Boot Starter** OpenTelemetry

---

## Agent Java — principe

- Un **java agent** : un JAR attaché à la JVM au démarrage

```bash
java -javaagent:/otel/opentelemetry-javaagent.jar -jar app.jar
```

- Instrumentation par **manipulation de bytecode** au chargement des classes
- Couvre **100+ bibliothèques** : Tomcat, Spring, JDBC, Kafka, gRPC, clients HTTP...
- Aucune modification du build ni du code
- L'application ne « sait » même pas qu'elle est instrumentée

---

## Spring Boot Starter

- Une **dépendance Maven/Gradle**, pas un agent :

```xml
<dependency>
  <groupId>io.opentelemetry.instrumentation</groupId>
  <artifactId>opentelemetry-spring-boot-starter</artifactId>
</dependency>
```

- S'appuie sur l'**auto-configuration Spring Boot**
- Mêmes variables `OTEL_*` (ou `application.properties`)
- Quand le préférer à l'agent ?
  - images **natives GraalVM** (pas de manipulation de bytecode possible)
  - maîtrise des dépendances par l'équipe de dev
  - politiques interdisant les agents JVM

---

## Agent vs Starter

| | Agent Java | Spring Boot Starter |
|---|---|---|
| Mise en œuvre | flag JVM | dépendance + rebuild |
| Qui la déploie | ops / plateforme | équipe de dev |
| Couverture | 100+ bibliothèques | Spring + libs principales |
| Démarrage | plus lent | plus rapide |
| GraalVM native | ❌ | ✔ |
| Modification du code | aucune | aucune (juste le build) |

- Même **chaîne** côté plateforme: OTLP → collecteur → backend
- **Contenu** diffèrent : l'agent réécrit le bytecode de ~toutes les libs Java (traces **plus détaillées**), le starter s'arrête à Spring et aux principales

---

## Ce que coûte l'agent

- La doc officielle **refuse de donner un chiffre unique** : trop de facteurs
  (JVM, machine, libs instrumentées, volume de spans) — elle demande de **mesurer chez soi**
- Ordres de grandeur, mesurés sur un « hello world » (JDK 21, 10 exécutions) :

| | sans agent | avec agent |
|---|---|---|
| Démarrage JVM | 0,02 s | **~1,45 s** (+1,4 s d'initialisation) |
| Mémoire résidente | 40 Mo | **~390 Mo** (heap fixé à 256 Mo) |

- ⚠️ C'est le **pire cas relatif** : sur une appli Spring Boot qui démarre déjà en
  plusieurs secondes, le surcoût de démarrage se dilue
- Repère de cette formation : `review-service` (Spring Boot, PostgreSQL, agent)
  tourne avec une limite de **512 Mio**
- Mesurer chez vous coûte peu : la même image, avec et sans `JAVA_TOOL_OPTIONS`
  ([méthode officielle](https://opentelemetry.io/docs/zero-code/java/agent/performance/))

---

## 🧪 LAB 2 — Instrumenter review-service

- **Partie 1** : déployer `review-service` tel que livré → invisible,
  puis activer l'**agent Java** (`JAVA_TOOL_OPTIONS`) → traces dans Jaeger
- **Partie 2** : reconstruire avec le **Starter** (`deploy.sh -p starter`) et comparer
- Service de référence « qui marche » : le **Ad Service** (Java + agent) de la démo

➡ [Lab 2 — Instrumentation zero-code](https://k8s-school.fr/labs/otel/fr/1_labs/20-otel-zero-code/index.html)

*Livrable : deux traces du même endpoint, une par agent, une par starter.*

---

## Annexe — Agent Java — installation

- Télécharger le JAR (releases GitHub `opentelemetry-java-instrumentation`)
- L'attacher à la JVM, au choix :
  - flag explicite : `java -javaagent:...`
  - variable d'environnement : `JAVA_TOOL_OPTIONS="-javaagent:..."`
    - lue par **toutes** les JVM au démarrage
    - idéal en conteneur : une simple variable d'env dans le manifest K8s
- Dans la formation : l'agent est **déjà dans l'image** (`/otel/opentelemetry-javaagent.jar`),
  seul `JAVA_TOOL_OPTIONS` l'active

---

## Annexe — Agent Java — configuration

- Tout se pilote par variables d'environnement `OTEL_*` :

```bash
OTEL_SERVICE_NAME=review-service
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317
OTEL_EXPORTER_OTLP_PROTOCOL=grpc
OTEL_RESOURCE_ATTRIBUTES=service.namespace=otel-demo
```

- Équivalents en propriétés système (`-Dotel.service.name=...`)
- Réglages fins : activer/désactiver une instrumentation, échantillonnage,
  `OTEL_INSTRUMENTATION_<NAME>_ENABLED=false`...

---

## Annexe — Agent Java — fonctionnement

- Au démarrage : l'agent s'enregistre comme `ClassFileTransformer`
- À chaque classe chargée : si une instrumentation la connaît,
  le bytecode est **réécrit à la volée** (ByteBuddy)
- Exemple sur `review-service` :
  - requête HTTP entrante → span **serveur** `GET /api/reviews`
  - appel JDBC → span **client** `SELECT reviews` (`db.system=postgresql`)
  - le **contexte de trace** est propagé automatiquement (headers W3C `traceparent`)
- Coût : démarrage plus lent, léger overhead CPU/mémoire
