---
title: Formation OpenTelemetry
---

# Formation OpenTelemetry

Bienvenue dans la formation **OpenTelemetry** (2 jours).

## Le fil rouge : l'Astronomy Shop 🔭

Vous rejoignez l'équipe SRE de l'**Astronomy Shop**, une boutique e-commerce en ligne
(la [démo officielle OpenTelemetry](https://opentelemetry.io/docs/demo/)), composée
d'une vingtaine de micro-services.

L'équipe Java vient de livrer un nouveau micro-service, **`review-service`**
(gestion des avis produits, API REST + PostgreSQL). Problème : il est **totalement
invisible** — aucune trace, aucune métrique, aucun log centralisé.

Sur les 2 jours, vous allez le rendre observable de bout en bout :

1. démarrer la stack d'observabilité (collecteur, Grafana, Jaeger, Prometheus, OpenSearch)
2. instrumenter `review-service` sans toucher au code (agent Java, Spring Boot Starter)
3. configurer le collecteur (métriques système et PostgreSQL)
4. construire un dashboard unifié logs / métriques / traces
5. produire des logs structurés corrélés aux traces
6. émettre des métriques métier
7. créer des spans manuels et maîtriser l'échantillonnage
8. protéger les données sensibles (RGPD, masquage des PII)

## Environnement technique

Toute la stack tourne dans un cluster **Kind** (Kubernetes local). Les commandes
Kubernetes nécessaires sont **toujours fournies** : Kubernetes n'est pas le sujet
du cours, c'est juste l'outil qui fait tourner la plateforme.

## Prérequis machine

* Docker
* `kubectl`, `helm`, `kind` (ou `ktbx`)
* 6 Go de RAM disponibles pour la démo
