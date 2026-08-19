---
marp: true
theme: custom-theme
paginate: true
backgroundColor: #ffffff
---

# Formation OpenTelemetry

## Chapitre 4 — Grafana

<img src="images/logo.svg" alt="K8s School Logo" width="50%">

---

## Grafana dans la chaîne OTel

- Grafana ne **stocke rien** : il fédère la visualisation des backends
- Dans la démo, tout est déjà câblé (provisionné par le chart Helm) :

| Signal | Backend | Datasource |
|--------|---------|------------|
| Métriques | Prometheus | `webstore-metrics` |
| Traces | Jaeger | `webstore-traces` |
| Logs | OpenSearch | `webstore-logs` |

---

## Datasources

- Une datasource = un backend + sa configuration de requête
- Provisionnables **par fichier YAML** (infra-as-code, comme dans la démo)
- Le vrai pouvoir : les **liens entre datasources**
  - **exemplars** : d'un point de métrique → la trace qui l'a produit
  - **tracesToLogsV2** : d'une trace → les logs corrélés
  - champ `traceId` d'un log → *View in Jaeger*
- C'est la **corrélation** du chapitre 1, rendue cliquable

---

## Visualisations

- **Time series** : l'essentiel des métriques (débit, latence, saturation)
- **Stat / Gauge** : valeur instantanée, SLO
- **Table** : inventaires, résultats de recherche de traces
- **Logs panel** : flux de logs avec niveau et détail dépliable
- **Traces panel** : waterfall de spans dans Grafana
- Bonnes pratiques : peu de panels, des unités correctes, le service en variable

---

## Dashboards

- Organisation : dossiers, tags, permissions
- **Variables** (`$service_name`...) : un dashboard générique pour N services

```promql
label_values(traces_span_metrics_calls_total, service_name)
```

- Export/import **JSON** : versionnable dans Git — c'est le livrable du lab
- Provisionnement par ConfigMap (sidecar Grafana) : les dashboards de la démo arrivent comme ça

---

## Alerting

- Une règle = une requête + une condition + une durée

```text
p95(traces_span_metrics_duration_milliseconds) > 20ms pendant 1 minute
```

- États : `Normal` → `Pending` → `Firing`
- **Contact points** : Slack, mail, webhook, OnCall...
- À retenir : alerter sur les **symptômes** (latence, erreurs — ce que voit l'utilisateur), pas sur les causes (CPU)

---

## 🧪 LAB 4 — Dashboard unifié

- Explorer les 3 datasources provisionnées
- Construire deux panels (métriques, traces), importer le reste
- Variable `service_name` pour basculer entre les services
- Une règle d'alerte sur la latence p95
- Exporter le dashboard en JSON (livrable à committer)
- Lab 4.1 : les exemplars, du point de métrique à la trace

➡ [Lab 4 — Dashboard unifié](https://k8s-school.fr/labs/otel/fr/1_labs/40-otel-grafana/index.html)
