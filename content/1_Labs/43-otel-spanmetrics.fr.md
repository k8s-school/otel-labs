---
title: 'Lab 4.2 — spanmetrics : des traces aux métriques RED'
date: 2026-09-09T23:00:00+02:00
draft: false
weight: 43
tags: ["spanmetrics", "Prometheus", "Grafana", "RED", "feature flag"]
---

Depuis le Lab 3, vos dashboards interrogent des métriques nommées `traces_span_metrics_*`. Personne ne les a écrites : le collecteur les **fabrique à partir des traces**. Ce lab explique d'où elles sortent, ce qu'elles savent et ne savent pas dire, puis s'en sert pour observer un incident déclenché à la souris.

## Prérequis

* Lab 4 terminé, les accès ouverts (`./scripts/open-ui.sh`), les variables chargées (`. ./scripts/env.sh`).

## 1. D'où viennent ces métriques

Un **connector** du collecteur, `spanmetrics`, est branché à la fois en sortie du pipeline `traces` et en entrée du pipeline `metrics` : chaque span qui passe est compté et chronométré.

```bash
kubectl get configmap otel-collector-agent -n otel-demo -o jsonpath='{.data.relay}' | grep -B2 -A6 'spanmetrics'
```

Sa configuration tient en deux caractères — `spanmetrics: {}` — donc tout ce qui suit vient des réglages par défaut. Il produit quatre séries :

| Métrique | Ce qu'elle compte |
|---|---|
| `traces_span_metrics_calls_total` | le nombre de spans (compteur) |
| `traces_span_metrics_duration_milliseconds_bucket` | leur durée, en seaux (histogramme) |
| `..._duration_milliseconds_count` / `..._sum` | de quoi calculer une moyenne |

C'est exactement le trio **RED** — *Rate, Errors, Duration* : le débit vient du compteur, les erreurs de son label `status_code`, la durée de l'histogramme. Trois questions de production, une seule source.

Regardez les étiquettes d'une série :

```bash
curl -s --get "http://$PF_HOST:$PROM_PORT/api/v1/query" \
  --data-urlencode 'query=traces_span_metrics_calls_total{service_name="review-service"}' | head -c 600
```

Trois étiquettes viennent du span — `span_name`, `span_kind`, `status_code` — les autres décrivent le service et son pod. **Il n'y a ni `trace_id`, ni identifiant de span parent**, et ce n'est pas un oubli : ces valeurs sont uniques par requête, en faire des étiquettes créerait une série Prometheus par requête. C'est le rôle des **exemplars** (Lab 4.1) de rattacher une trace à un point sans en faire une dimension.

Conséquence à retenir : ces métriques savent **combien** et **combien de temps**, jamais **dans quel ordre**. Pour la structure d'un appel, il faut ouvrir la trace.

## 2. Le piège : une requête n'est pas un span

Un `GET /api/reviews` de votre `review-service` produit **trois** spans :

```
GET /api/reviews                 kind = server     ← la requête entière
HikariDataSource.getConnection   kind = internal   ← dedans
SELECT otel                      kind = client     ← dedans
```

Une requête, vue à trois niveaux de détail. Mais spanmetrics les chronomètre séparément et les verse dans le même histogramme : les deux tiers de spans quasi instantanés tirent la distribution vers le bas. Mesuré sous charge sur le cluster de la formation :

| Requête | p95 affiché |
|---|---|
| sans filtre | **6,6 ms** |
| `span_kind="SPAN_KIND_SERVER"` | **22,9 ms** |
| p85 de la seule opération HTTP | 5,9 ms |

Le p95 non filtré suit en réalité le **p85** des requêtes — et il se déplace si l'instrumentation change : l'agent Java du Lab 2 produit cinq spans par requête au lieu de trois, ce qui ramène le chiffre affiché vers le p75. Même service, même latence réelle, chiffre différent.

D'où le filtre du dashboard du Lab 4 :

```promql
histogram_quantile(0.95, sum(rate(traces_span_metrics_duration_milliseconds_bucket{
  service_name=~"$service_name", span_kind=~"SPAN_KIND_SERVER|SPAN_KIND_CONSUMER"}[2m])) by (le, span_kind))
```

`SPAN_KIND_SERVER` retient une requête HTTP ou gRPC reçue, `SPAN_KIND_CONSUMER` un message lu dans une file — les deux formes de **travail entrant**. Les deux sont nécessaires : `accounting` et `fraud-detection` ne sont jamais appelés en HTTP, ils consomment du Kafka, et le filtre `SERVER` seul laisse leur panel vide.

Le `by (le, span_kind)` trace une courbe par valeur plutôt que de les additionner : un service qui sert du HTTP *et* consomme du Kafka a deux populations de latences, qu'il n'y a aucune raison de mélanger.

> 💡 `span_kind` dit quel bout de l'appel un span mesure, **pas** sa profondeur dans l'arbre. Chez `accounting`, la racine est un span `INTERNAL` et le `CONSUMER` est son enfant.

## 3. Le dashboard que la démo livre

Ouvrez **« Spanmetrics Demo Dashboard »** :

```bash
echo "http://$PF_HOST:$UI_PORT/grafana/d/W2gX2zHVk48"
```

Il affiche les trois signaux RED, et surtout il ajoute une variable que le Lab 4 n'avait pas : **`span_name`**. Sélectionnez une opération précise et les latences cessent d'être un mélange — c'est la parade au piège de l'étape 2, par l'autre bout.

Trois panels à regarder :

* **Top 7 Services Mean Rate** — le débit, service par service ;
* **Top 7 Services Mean ERROR Rate** — le même compteur filtré sur `status_code="STATUS_CODE_ERROR"` ;
* **Top 3x3 - Service Latency** — le p95, groupé `by (le, service_name)`.

> 💡 Une seule requête est active par panel, les autres sont masquées (`hide`) : ce sont des variantes prêtes à l'emploi pour basculer d'un quantile à l'autre. Regardez-les dans l'éditeur, pas dans la légende.

Ce dashboard n'applique aucun filtre `span_kind` : vous savez maintenant ce que ses latences valent tant qu'on ne choisit pas de `span_name`.

## 4. Provoquer un incident, sans charger sa machine

La démo embarque quinze **feature flags** de panne, tous à `off`. Ouvrez leur interface, `http://$PF_HOST:$UI_PORT/feature`, et basculez **`productCatalogFailure`** sur `on`.

> ⚠️ Passez **par cette interface**, pas par `kubectl`. Le pod `flagd` monte un `emptyDir`, pas la ConfigMap `flagd-config` : modifier la ConfigMap n'atteint pas un pod déjà démarré. L'interface, elle, écrit dans le fichier que `flagd` surveille, et le changement est poussé aux services en quelques secondes.

Vérifiez tout de suite, un produit tombe et pas les autres :

```bash
curl -s -o /dev/null -w "OLJCESPC7Z -> %{http_code}\n" http://$PF_HOST:$UI_PORT/api/products/OLJCESPC7Z
curl -s -o /dev/null -w "66VCHSJNUP -> %{http_code}\n" http://$PF_HOST:$UI_PORT/api/products/66VCHSJNUP
```

Puis **patientez une dizaine de minutes**. Ce n'est pas une approximation prudente, c'est ce que coûte la chaîne : le load generator ne redemande ce produit que de temps en temps, le collecteur n'exporte que toutes les 60 s, et `rate()` a besoin de deux points. Mesuré en salle : les premières erreurs apparaissent **9 minutes** après le clic. Listez-les :

```bash
curl -s --get "http://$PF_HOST:$PROM_PORT/api/v1/query" \
  --data-urlencode 'query=sum by (service_name,span_name) (rate(traces_span_metrics_calls_total{status_code="STATUS_CODE_ERROR"}[5m])) > 0'
```

{{%expand "Ce que vous devez voir" %}}
Huit spans, sur quatre services :

```
load-generator   GET
frontend-proxy   GET
frontend-proxy   router frontend egress
frontend         GET /api/products/{productId}
frontend         GET /api/products/[productId]/index
frontend         executing api route (pages) /api/products/[productId]/index
frontend         oteldemo.ProductCatalogService/GetProduct
product-catalog  oteldemo.ProductCatalogService/GetProduct
```

Une seule panne, et toute la chaîne d'appel s'allume — jusqu'au générateur de charge. Les deux dernières lignes sont **la même opération vue des deux côtés** : `kind=client` chez l'appelant, `kind=server` chez l'appelé. C'est le tracing distribué qui rend cette lecture possible ; une métrique applicative classique n'aurait montré que le dernier maillon.
{{% /expand%}}

## 5. Alerter sur les erreurs

Un taux d'erreur se surveille mieux qu'une latence : il ne dépend ni de la machine ni de la charge. Installez la règle :

```bash
GRAFANA="http://$PF_HOST:$UI_PORT/grafana"

# le dossier ; s'il existe déjà, Grafana répond 412, sans conséquence
curl -sS -X POST "$GRAFANA/api/folders" -H "Content-Type: application/json" \
  -d '{"uid":"otel-training","title":"Formation OTel"}'

curl -sS -X POST "$GRAFANA/api/v1/provisioning/alert-rules" \
  -H "Content-Type: application/json" -H "X-Disable-Provenance: true" \
  -d @content/1_Labs/43-otel-spanmetrics-alert.json

echo "$GRAFANA/alerting/list"
```

Elle surveille une expression qui tient en une ligne :

```promql
sum(rate(traces_span_metrics_calls_total{service_name="product-catalog", status_code="STATUS_CODE_ERROR"}[5m]))
```

Seuil : **plus de zéro**, pendant **1 minute**. Chronologie relevée en salle, flag basculé à T :

| | |
|---|---|
| T + 9 min | premières erreurs mesurables (0,026 /s) |
| T + 10 min | `Pending` |
| T + 10 min 30 | `Firing` |

Remettez le flag sur `off` et la règle redescend.

> 💡 La fenêtre `[5m]`, et non `[2m]`, n'est pas un détail. La boutique reçoit moins d'une requête par seconde : sur deux minutes, une série peut n'avoir aucun point neuf, la requête renvoie *vide*, et comme la règle est en `noDataState: OK` elle retomberait à `Normal` en plein incident. Une fenêtre large amortit ces trous.

**Remettez le flag sur `off`** avant de quitter le lab.

## Livrable

La liste des huit spans en erreur relevée à l'étape 4, et la règle vue passer en `Firing`. Et une phrase de votre main : pourquoi le p95 d'un service, sans filtre `span_kind`, n'est pas le p95 de ses requêtes.
