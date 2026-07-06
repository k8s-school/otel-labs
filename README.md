# Formation OpenTelemetry

Supports de la formation OpenTelemetry (2 jours) : labs, slides, micro-service
d'exercice et scripts d'infrastructure.

- Programme de référence : `OpenTelemetry (1).rtf` (officiel) · `programme-otel-michelin.md` (run-sheet formateur)
- Fil rouge : rendre observable `review-service`, un micro-service Spring Boot
  ajouté à l'[Astronomy Shop](https://opentelemetry.io/docs/demo/) (démo officielle OpenTelemetry)

## Arborescence

| Répertoire | Contenu |
|---|---|
| `content/1_Labs/` | Labs (Hugo/Relearn, fr) + corrections shell (`*-solution.sh`, en) |
| `slides/` | Slides Marp (fr), build : `slides/md2pdf.sh` |
| `apps/review-service/` | Micro-service Spring Boot (API avis produits + PostgreSQL) |
| `scripts/` | `up.sh` / `down.sh` / `deploy.sh` / `open-ui.sh` |
| `manifests/` | Values Helm de la démo (formation, CI) |

## Démarrage rapide (parcours participant)

```bash
./scripts/up.sh -c        # cluster Kind + démo OpenTelemetry (pinnée 0.40.9)
./scripts/open-ui.sh      # UIs sur http://localhost:8080 (shop, Grafana, Jaeger)
./scripts/deploy.sh       # build + kind load + deploy du review-service
```

## Prévisualiser les labs

```bash
hugo serve                # http://localhost:1313
```

## Rejouer les labs (corrections)

```bash
./content/1_Labs/10-otel-stack-solution.sh      # stack d'observabilité
./content/1_Labs/20-otel-zero-code-solution.sh  # agent Java + starter
./content/1_Labs/30-otel-collector-solution.sh  # hostmetrics + postgresql
./content/1_Labs/40-otel-grafana-solution.sh    # dashboard 3 signaux
./content/1_Labs/50-otel-logs-solution.sh       # logs corrélés (OpenSearch)
./content/1_Labs/60-otel-metrics-solution.sh    # métriques métier + count
./content/1_Labs/70-otel-traces-solution.sh     # trace multi-services + tail sampling
./content/1_Labs/80-otel-security-solution.sh   # masquage PII (SDK + collecteur)
```

Les scripts sont **séquentiels** (chacun suppose les précédents). La CI
(`.github/workflows/ci.yml`) rejoue exactement cette séquence sur un cluster
Kind (ktbx), avec `manifests/values-ci.yaml` en plus (composants lourds
désactivés).

## État

- ✅ Chapitres 1–8 : labs + corrections + slides
- ✅ Chapitres 9–10 : slides (Spring facultatif, Conclusion)
- 🔍 En validation manuelle par le formateur
