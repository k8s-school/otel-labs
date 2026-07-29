---
marp: true
theme: custom-theme
paginate: true
backgroundColor: #ffffff
---

# Formation OpenTelemetry

## Chapitre 3 — Le collecteur

<img src="images/logo.svg" alt="K8s School Logo" width="50%">

---

## Pourquoi un collecteur ?

- Le SDK **pourrait** exporter directement vers Jaeger/Prometheus... mais :
  - chaque appli devrait connaître **tous les backends** (config dupliquée)
  - pas de **tampon** : un backend lent fait souffrir l'application
  - impossible de **transformer/filtrer** centralement (PII, coûts, routage)
- Le collecteur **découple** producteurs et consommateurs :
  - l'appli n'a qu'une cible : **OTLP vers le collecteur**
  - la plateforme décide du reste, **sans redéployer les applis**

---

## Le pipeline

```
receivers  ─►  processors  ─►  exporters
 (entrée)     (transformation)   (sortie)

            ┌── extensions (santé, debug...)
            └── connectors (relier deux pipelines)
```

- Un **pipeline** par type de signal : `traces`, `metrics`, `logs`
- Déclaré dans `service.pipelines` — un composant configuré mais
  **non référencé** dans un pipeline est inactif

---

## Installation & modes de déploiement

- Un binaire Go unique, configuré en YAML — chart Helm officiel
- **Agent** : un collecteur près de chaque application
  - en K8s : **DaemonSet** (un par nœud) — le mode de la démo
  - collecte locale (hostmetrics, logs de fichiers), faible latence
- **Gateway** : un pool central de collecteurs
  - point de contrôle unique : filtrage, sampling, routage multi-backends
- En pratique : souvent **les deux**, agents → gateway

---

## Distributions

- **Core** : les composants essentiels, maintenus par le projet
- **Contrib** : ~100 receivers/processors/exporters communautaires
  - c'est l'image de la démo (`otel/opentelemetry-collector-contrib`)
- **Distributions vendors** : AWS ADOT, Grafana Alloy, Datadog...
- **Builder (`ocb`)** : composer son collecteur sur mesure
  (uniquement les composants nécessaires → surface d'attaque réduite)

---

## Receivers

- Font entrer la donnée : en **push** (l'appli envoie) ou en **pull** (le collecteur interroge)
- **`otlp`** : LE receiver standard — gRPC 4317 / HTTP 4318
- **`hostmetrics`** : CPU, mémoire, disque, réseau du nœud (scrapers)
- Receivers « produit » : `postgresql`, `kafkametrics`, `prometheus`, `filelog`...

```yaml
receivers:
  postgresql:
    endpoint: postgresql:5432
    username: root
    password: otel
```

---

## Processors (1/2)

- Transforment la donnée **entre** réception et export
- **`memory_limiter`** : garde-fou mémoire
- **`batch`** : regroupe avant export
- **`attributes` / `resource`** : ajouter/supprimer/modifier des attributs
- **`filter`** : jeter des données (spans de healthcheck, métriques inutiles...)
- **`transform`** : transformations avancées avec le langage **OTTL**
- **`resourcedetection`** : enrichit avec l'environnement (host, cloud, K8s)

---

## Processors (2/2) — l'ordre compte

L'ordre de la liste **est** l'ordre d'exécution. Ordre recommandé :

1. **`memory_limiter`** — délester avant d'accumuler
2. ce qui **jette** de la donnée (`filter`, échantillonnage)
3. ce qui dépend du contexte de connexion (`k8sattributes`)
4. ce qui **enrichit** / transforme (`resource`, `transform`)
5. **`batch`** — inutile de regrouper ce qui sera jeté ou modifié après

```yaml
processors: [memory_limiter, resourcedetection, resource, transform, batch]
```

⚠️ Le [schéma officiel](https://opentelemetry.io/docs/collector/) place `Batch` en
tête : c'est une illustration du *concept* de pipeline, pas une prescription.

---

## Le langage OTTL

- **O**penTelemetry **T**ransformation **L**anguage : `set()`, `delete_key()`, `replace_pattern()`... + conditions `where`
- Exemple réel de la démo (normalisation des noms de spans du frontend) :

```yaml
transform:
  trace_statements:
    - context: span
      statements:
        - set(span.attributes["http.route"], "/api/cart")
          where IsMatch(span.attributes["http.target"], "\\/api\\/cart")
```

- Le même langage servira au **masquage des données sensibles** (module Sécurité, J2)

---

## Connectors

- Relient la **sortie** d'un pipeline à l'**entrée** d'un autre
- **`forward`** : chaînage simple
- **`routing`** : aiguiller selon une condition (par tenant, par environnement)
- **`count`** / **`spanmetrics`** : dériver des **métriques** depuis des spans
  - la démo utilise `spanmetrics` : latences/débits par opération calculés
    depuis le pipeline traces, sans instrumenter les applis

---

## Exporters

- Font sortir la donnée vers les backends
- **`debug`** : affiche dans les logs du collecteur — l'outil n°1 de mise au point
- **`file`** : écrit dans un fichier (archivage, debug)
- **`otlp` / `otlphttp`** : vers tout backend compatible OTLP
- Dans la démo :

```yaml
traces  → otlp/jaeger        (gRPC vers Jaeger)
metrics → otlphttp/prometheus (OTLP natif Prometheus)
logs    → opensearch
```

---

## Extensions

- Fonctions transverses, hors du flux de données
- **`health_check`** : endpoint HTTP de vivacité (probes K8s)
- **`zpages`** : pages web de debug embarquées
  - `/debug/pipelinez` : les pipelines actifs et leurs composants
  - `/debug/tracez` : échantillons de spans récents

```yaml
service:
  extensions: [health_check, zpages]
```

---

## Synthèse : le collecteur de la démo

```
review-service ─┐                                    ┌─► Jaeger
frontend, cart ─┼─► otlp ──► TRACES ──────────────────┤
   (OTLP push)  │            │                       └─► spanmetrics ─┐
                │            └── k8sattributes, memory_limiter,       │
                │               resourcedetection, resource,          │
                │               transform (OTTL), batch               │
                │                                                     │
kafka ──────────┼─► kafkametrics ──► METRICS ◄────────────────────────┘
kubelet ────────┘   kubeletstats      └──────────────────► Prometheus
   (pull)           k8s_cluster
                                      LOGS ──────────────► OpenSearch
```

- **3 pipelines** indépendants, une même config, **zéro modification applicative**
- Un composant n'existe que s'il est **cité dans `service.pipelines`**
- Ajouter une source = ajouter un receiver **et** le brancher au pipeline

---

## 🧪 LAB 3 — Configurer le collecteur

- Lire la configuration réelle du collecteur de la démo
- Ajouter le receiver **`hostmetrics`** (métriques système)
- Ajouter le receiver **`postgresql`** (métriques produit — la base de `review-service`)
- Activer **zPages** et observer le pipeline
- Vérifier les nouvelles métriques dans **Prometheus**

➡ [Lab 3 — Configuration du collecteur](https://k8s-school.fr/labs/otel/fr/1_labs/30-otel-collector/index.html)

*Livrable : métriques `system_*` et `postgresql_*` visibles dans Prometheus.*
