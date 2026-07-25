---
marp: true
theme: custom-theme
paginate: true
backgroundColor: #ffffff
---

# Formation OpenTelemetry

## Chapitre 1 — Introduction

<img src="images/logo.svg" alt="K8s School Logo" width="50%">

---

## Objectifs de la formation

- Améliorer l'**observabilité** de vos applications avec OpenTelemetry
- Couvrir **l'intégration, la configuration et l'utilisation** des composantes de la plateforme
- **~65 % de pratique** : une stack complète tourne sur votre machine dès ce matin

**Fil rouge** 🔭 : vous rejoignez l'équipe SRE de l'**Astronomy Shop** (démo officielle OpenTelemetry). Un nouveau micro-service Java, `review-service`, vient d'être livré : **il est invisible**. En 2 jours, vous le rendez observable de bout en bout.

---

## Monitoring vs observabilité

- **Monitoring** : surveiller des symptômes **connus à l'avance**
  - « le CPU dépasse 80 % », « le service ne répond plus »
  - dashboards et alertes figés, par composant
- **Observabilité** : comprendre un état interne **à partir des signaux émis**
  - « pourquoi les commandes des clients allemands échouent-elles depuis 14h ? »
  - explorer des questions **qu'on n'avait pas prévues**
- Le monitoring classique ne suffit plus :
  - micro-services : une requête traverse **10+ services**
  - défaillances **émergentes**, pas de « root cause » unique
  - environnements éphémères (conteneurs, autoscaling)

---

## Les trois piliers

| Signal | Question | Exemple |
|--------|----------|---------|
| **Logs** | Que s'est-il passé ? | `Payment declined for order 42` |
| **Métriques** | Combien / à quel rythme ? | `http_requests_total`, latence p99 |
| **Traces** | Où, dans quel service ? | parcours d'une requête à travers 10 services |

- Chaque pilier seul est **insuffisant**
- La valeur naît de la **corrélation** : de l'alerte (métrique) à la trace, de la trace au log

---

## Du monitoring à l'observabilité 2.0

- **Corrélation** : tous les signaux partagent le même contexte (`trace_id`, `service.name`)
- **Cardinalité** : des attributs riches (client, version, région...)
  - la limite des métriques pré-agrégées
- **Wide events** : un événement large et structuré par requête, qu'on interroge après coup
- La tendance : ne plus séparer les 3 piliers en silos, mais les **relier par le contexte**

---

## OpenTelemetry : définition

- Projet **CNCF** (fusion d'OpenTracing et OpenCensus, 2019)
- 2ᵉ projet le plus actif de la CNCF après Kubernetes
- Un **standard ouvert** pour produire et transporter la télémétrie :
  - **API & SDK** par langage (Java, Go, Python, .NET...)
  - **Protocole OTLP**
  - **Conventions sémantiques**
  - **Collecteur**
- Ce que le standard **ne couvre pas** : le stockage et la visualisation
  - pas de base de données, pas de dashboard → Jaeger, Prometheus, Grafana, vendors...

---

## Écosystème et architecture

```
Application                     Collecteur                Backends
┌───────────────┐   OTLP    ┌──────────────────┐    ┌────────────────┐
│  API + SDK    │ ────────► │ receive/process/ │ ─► │ Jaeger (traces)│
│  (ou agent)   │           │ export           │ ─► │ Prometheus     │
└───────────────┘           └──────────────────┘ ─► │ OpenSearch     │
                                                    └───────┬────────┘
                                                     Grafana (visualisation)
```

- L'application émet via le **SDK** (ou un agent zero-code)
- Le **collecteur** centralise, transforme, route
- Les **backends** stockent ; Grafana fédère la visualisation

---

## Conventions sémantiques

- Le **cœur de la valeur** d'OpenTelemetry : tout le monde nomme pareil
- `service.name`, `http.request.method`, `http.response.status_code`, `db.system`...
- Conséquences :
  - les dashboards et alertes deviennent **portables**
  - les outils **comprennent** les données sans configuration
  - la corrélation entre signaux devient **automatique**
- Registre officiel : <https://opentelemetry.io/docs/specs/semconv/>

---

## Le protocole OTLP

- **O**pen**T**e**L**emetry **P**rotocol : un protocole unique pour les 3 signaux
- Deux transports :
  - **gRPC** — port `4317`
  - **HTTP/protobuf** — port `4318`
- Utilisé de bout en bout : SDK → collecteur → collecteur → backend
- Payload binaire (protobuf), compression, batching : conçu pour le volume

---

## API, SDK, distributions, fournisseurs

- **API** : les interfaces (`Tracer`, `Meter`, `Logger`) — dépendance des bibliothèques
  - no-op par défaut : instrumenter une lib ne coûte rien si le SDK est absent
- **SDK** : l'implémentation — échantillonnage, processors, exporters
- **Distributions** : un SDK/collecteur pré-packagé par un éditeur
  (Grafana, Datadog, AWS ADOT, Elastic...)
- **Fournisseurs** : backends compatibles OTLP — le standard évite le **vendor lock-in** :
  on change de backend sans réinstrumenter

---

## 🧪 LAB 1 — Démarrage de la stack

- Créer le cluster Kind et installer la démo OpenTelemetry
- Accéder à Grafana, Jaeger et à la boutique
- Suivre une commande de bout en bout dans Jaeger
- Constater que `review-service` est **invisible**

➡ [Lab 1 — Démarrage de la stack d'observabilité](https://k8s-school.fr/labs/otel/fr/1_labs/10-otel-stack/index.html)

*Livrable : une trace de checkout complète dans Jaeger.*
