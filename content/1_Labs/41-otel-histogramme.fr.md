---
title: 'Lab 4.1 — Lire un panel de latence : heatmap, p95 et faux pics'
date: 2026-08-18T10:30:00+02:00
draft: false
weight: 41
tags: ["Grafana", "PromQL", "histogramme", "heatmap", "Prometheus"]
aliases:
  - /fr/1_labs/42-otel-grafana-bonus/
---

Page de lecture : rien à construire, rien à déployer. Le dashboard « Cart Service Exemplars », livré par la démo, met face à face deux panels pour la même opération du panier : une **heatmap** et une courbe de **p95**. Ils affichent la **même métrique**. On commence par la heatmap — c'est la distribution entière —, et le p95 s'en déduit par une seule opération de lecture.

## 1. La heatmap, mot à mot

La requête du panel « AddItem Latency Heatmap with Exemplars » :

```promql
sum by(le) (rate(app_cart_add_item_latency_seconds_bucket[$__rate_interval]))
```

Trois morceaux, à lire de l'intérieur vers l'extérieur.

**`_bucket` et `le` : des seaux, pas des durées.** Le service `cart` ne publie pas la durée de chaque appel — ce serait revenir aux traces. Il les **range dans des seaux** : `..._bucket{le="0.005"}` compte les appels qui ont duré **5 ms ou moins** (`le` = *less or equal*, et la métrique est en **secondes**). Ces seaux sont **cumulatifs** — un appel de 3 ms incrémente aussi celui des 10 ms, celui des 25 ms, et ainsi de suite jusqu'à `le="+Inf"` qui les contient tous.

Relevé sur le cluster de la formation :

```text
app_cart_add_item_latency_seconds_bucket{le="0.005"}   1935
app_cart_add_item_latency_seconds_bucket{le="0.01"}    1935
app_cart_add_item_latency_seconds_bucket{le="0.025"}   1936
app_cart_add_item_latency_seconds_bucket{le="0.05"}    1936
   …
app_cart_add_item_latency_seconds_bucket{le="+Inf"}    1936
```

Ces lignes se lisent : 1936 appels observés, dont 1935 sous 5 ms. Le 1936ᵉ est passé entre 10 et 25 ms — c'est le seul endroit où le compteur augmente. Pour lister les seaux de **votre** cluster, dans *Explore* :

```promql
sum by(le) (app_cart_add_item_latency_seconds_bucket)
```

**`rate(...[$__rate_interval])` : ramener au récent.** Chaque seau est un compteur **cumulé depuis le démarrage du service**. Sans `rate`, le panel décrirait la distribution des latences *depuis toujours*, une image presque immobile où l'incident d'il y a trois heures pèse autant que la minute en cours. `$__rate_interval` est la variable de Grafana qui adapte la fenêtre au zoom du dashboard.

**`sum by(le)` : additionner les instances, garder les seaux.** Le service peut tourner en plusieurs pods : `sum` les réunit, `by(le)` **conserve le découpage par seau**. Un `sum` nu écraserait aussi `le` : il ne resterait plus aucune distribution à afficher.

**Ce que Grafana en fait.** La requête rend une série par seau. Grafana pose une **ligne par seau**, et comme les seaux sont cumulatifs, il **soustrait chaque seau de son voisin du dessous** pour obtenir la part propre de chacun. Cette part donne la couleur de la cellule :

<svg viewBox="0 0 920 372" width="100%" role="img" aria-label="De la requete PromQL a la heatmap : les series par seau, la de-cumulation, la grille" style="max-width:920px;height:auto;display:block;margin:1.2rem auto">
<defs><marker id="ar1" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="currentColor"/></marker></defs>
<text x="12" y="26" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="15" font-weight="600" text-anchor="start" fill="currentColor">① Une série par seau</text><text x="12" y="46" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="12.5" font-weight="normal" text-anchor="start" fill="currentColor" opacity="0.75">req/s cumulées, à l’instant t</text><text x="296" y="26" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="15" font-weight="600" text-anchor="start" fill="currentColor">② Grafana dé-cumule</text><text x="296" y="46" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="12.5" font-weight="normal" text-anchor="start" fill="currentColor" opacity="0.75">part propre de chaque seau</text><text x="582" y="26" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="15" font-weight="600" text-anchor="start" fill="currentColor">③ Une colonne par instant</text><text x="582" y="46" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="12.5" font-weight="normal" text-anchor="start" fill="currentColor" opacity="0.75">couleur = nombre de requêtes</text><line x1="12" y1="80" x2="908" y2="80" stroke="currentColor" stroke-width="1" opacity="0.12"/>
<text x="16" y="102" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13.5" font-weight="normal" text-anchor="start" fill="currentColor">le="+Inf"</text><text x="246" y="102" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13.5" font-weight="600" text-anchor="end" fill="currentColor">10,0</text><rect x="296" y="87" width="7" height="20" rx="3" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.35"/>
<text x="311" y="102" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13.5" font-weight="normal" text-anchor="start" fill="currentColor">0,1</text><rect x="584" y="82" width="50" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="638" y="82" width="50" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="692" y="82" width="50" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="746" y="82" width="50" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="800" y="82" width="50" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="854" y="82" width="50" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<line x1="12" y1="114" x2="908" y2="114" stroke="currentColor" stroke-width="1" opacity="0.12"/>
<text x="16" y="136" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13.5" font-weight="normal" text-anchor="start" fill="currentColor">le="0.1"</text><text x="246" y="136" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13.5" font-weight="600" text-anchor="end" fill="currentColor">9,9</text><rect x="296" y="121" width="8" height="20" rx="3" fill="#fde68a" stroke="currentColor" stroke-opacity="0.35"/>
<text x="312" y="136" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13.5" font-weight="normal" text-anchor="start" fill="currentColor">0,2</text><rect x="584" y="116" width="50" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="638" y="116" width="50" height="30" rx="2" fill="#fde68a" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="692" y="116" width="50" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="746" y="116" width="50" height="30" rx="2" fill="#fde68a" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="800" y="116" width="50" height="30" rx="2" fill="#fde68a" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="854" y="116" width="50" height="30" rx="2" fill="#fde68a" stroke="currentColor" stroke-opacity="0.18"/>
<line x1="12" y1="148" x2="908" y2="148" stroke="currentColor" stroke-width="1" opacity="0.12"/>
<text x="16" y="170" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13.5" font-weight="normal" text-anchor="start" fill="currentColor">le="0.075"</text><text x="246" y="170" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13.5" font-weight="600" text-anchor="end" fill="currentColor">9,7</text><rect x="296" y="155" width="20" height="20" rx="3" fill="#fbbf24" stroke="currentColor" stroke-opacity="0.35"/>
<text x="324" y="170" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13.5" font-weight="normal" text-anchor="start" fill="currentColor">0,5</text><rect x="584" y="150" width="50" height="30" rx="2" fill="#fde68a" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="638" y="150" width="50" height="30" rx="2" fill="#fbbf24" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="692" y="150" width="50" height="30" rx="2" fill="#fbbf24" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="746" y="150" width="50" height="30" rx="2" fill="#fbbf24" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="800" y="150" width="50" height="30" rx="2" fill="#f59e0b" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="854" y="150" width="50" height="30" rx="2" fill="#fbbf24" stroke="currentColor" stroke-opacity="0.18"/>
<line x1="12" y1="182" x2="908" y2="182" stroke="currentColor" stroke-width="1" opacity="0.12"/>
<text x="16" y="204" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13.5" font-weight="normal" text-anchor="start" fill="currentColor">le="0.05"</text><text x="246" y="204" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13.5" font-weight="600" text-anchor="end" fill="currentColor">9,2</text><rect x="296" y="189" width="87" height="20" rx="3" fill="#ea580c" stroke="currentColor" stroke-opacity="0.35"/>
<text x="391" y="204" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13.5" font-weight="normal" text-anchor="start" fill="currentColor">2,2</text><rect x="584" y="184" width="50" height="30" rx="2" fill="#f59e0b" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="638" y="184" width="50" height="30" rx="2" fill="#ea580c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="692" y="184" width="50" height="30" rx="2" fill="#f59e0b" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="746" y="184" width="50" height="30" rx="2" fill="#ea580c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="800" y="184" width="50" height="30" rx="2" fill="#ea580c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="854" y="184" width="50" height="30" rx="2" fill="#ea580c" stroke="currentColor" stroke-opacity="0.18"/>
<line x1="12" y1="216" x2="908" y2="216" stroke="currentColor" stroke-width="1" opacity="0.12"/>
<text x="16" y="238" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13.5" font-weight="normal" text-anchor="start" fill="currentColor">le="0.025"</text><text x="246" y="238" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13.5" font-weight="600" text-anchor="end" fill="currentColor">7,0</text><rect x="296" y="223" width="158" height="20" rx="3" fill="#b91c1c" stroke="currentColor" stroke-opacity="0.35"/>
<text x="462" y="238" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13.5" font-weight="normal" text-anchor="start" fill="currentColor">4,0</text><rect x="584" y="218" width="50" height="30" rx="2" fill="#b91c1c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="638" y="218" width="50" height="30" rx="2" fill="#b91c1c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="692" y="218" width="50" height="30" rx="2" fill="#b91c1c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="746" y="218" width="50" height="30" rx="2" fill="#b91c1c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="800" y="218" width="50" height="30" rx="2" fill="#b91c1c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="854" y="218" width="50" height="30" rx="2" fill="#b91c1c" stroke="currentColor" stroke-opacity="0.18"/>
<line x1="12" y1="250" x2="908" y2="250" stroke="currentColor" stroke-width="1" opacity="0.12"/>
<text x="16" y="272" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13.5" font-weight="normal" text-anchor="start" fill="currentColor">le="0.01"</text><text x="246" y="272" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13.5" font-weight="600" text-anchor="end" fill="currentColor">3,0</text><rect x="296" y="257" width="79" height="20" rx="3" fill="#ea580c" stroke="currentColor" stroke-opacity="0.35"/>
<text x="383" y="272" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13.5" font-weight="normal" text-anchor="start" fill="currentColor">2,0</text><rect x="584" y="252" width="50" height="30" rx="2" fill="#ea580c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="638" y="252" width="50" height="30" rx="2" fill="#ea580c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="692" y="252" width="50" height="30" rx="2" fill="#ea580c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="746" y="252" width="50" height="30" rx="2" fill="#ea580c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="800" y="252" width="50" height="30" rx="2" fill="#f59e0b" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="854" y="252" width="50" height="30" rx="2" fill="#ea580c" stroke="currentColor" stroke-opacity="0.18"/>
<line x1="12" y1="284" x2="908" y2="284" stroke="currentColor" stroke-width="1" opacity="0.12"/>
<text x="16" y="306" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13.5" font-weight="normal" text-anchor="start" fill="currentColor">le="0.005"</text><text x="246" y="306" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13.5" font-weight="600" text-anchor="end" fill="currentColor">1,0</text><rect x="296" y="291" width="40" height="20" rx="3" fill="#f59e0b" stroke="currentColor" stroke-opacity="0.35"/>
<text x="344" y="306" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13.5" font-weight="normal" text-anchor="start" fill="currentColor">1,0</text><rect x="584" y="286" width="50" height="30" rx="2" fill="#f59e0b" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="638" y="286" width="50" height="30" rx="2" fill="#fbbf24" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="692" y="286" width="50" height="30" rx="2" fill="#f59e0b" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="746" y="286" width="50" height="30" rx="2" fill="#f59e0b" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="800" y="286" width="50" height="30" rx="2" fill="#fbbf24" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="854" y="286" width="50" height="30" rx="2" fill="#f59e0b" stroke="currentColor" stroke-opacity="0.18"/>
<line x1="12" y1="318" x2="908" y2="318" stroke="currentColor" stroke-width="1" opacity="0.12"/>
<rect x="744" y="78" width="54" height="242" fill="none" stroke="#3b82f6" stroke-width="2.5" rx="4"/>
<text x="771" y="70" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="12.5" font-weight="600" text-anchor="middle" fill="#3b82f6">instant t</text><line x1="256" y1="199" x2="284" y2="199" stroke="currentColor" stroke-width="1.6" marker-end="url(#ar1)" opacity="0.7"/>
<line x1="546" y1="199" x2="574" y2="199" stroke="currentColor" stroke-width="1.6" marker-end="url(#ar1)" opacity="0.7"/>
<text x="12" y="350" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="12.5" font-weight="normal" text-anchor="start" fill="currentColor" opacity="0.75">une ligne = un seau (label le, en secondes)</text><text x="584" y="350" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="12.5" font-weight="normal" text-anchor="start" fill="currentColor" opacity="0.75">temps →</text></svg>

*Chiffres d'illustration, en req/s. Une colonne de la heatmap, lue de bas en haut, est la **distribution des latences à cet instant** : ici le gros du trafic entre 10 et 25 ms, et une frange qui traîne au-dessus.*

> 💡 **La dé-cumulation est bien faite par Grafana**, pas par PromQL. Elle se vérifie dans *Panel → Inspect → Panel JSON* : le panel porte `"calculate": false` — « les données arrivent déjà en seaux, ne recalcule pas d'histogramme » — et `"filterValues": {"le": 1e-9}`, qui masque les cellules restées vides.

## 2. Ce qu'un chiffre unique ne peut pas montrer

Un p95 ne peut pas dire si les requêtes forment **une** population ou **deux**. Or c'est fréquent : une réponse servie depuis un cache et une réponse calculée n'ont pas la même durée, et l'histogramme le voit tout de suite.

<svg viewBox="0 0 920 300" width="100%" role="img" aria-label="Heatmap bimodale : deux bandes horizontales que le p95 ne montre pas" style="max-width:920px;height:auto;display:block;margin:1.2rem auto">
<defs><marker id="ar3" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="currentColor"/></marker></defs>
<text x="12" y="78" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13.5" font-weight="normal" text-anchor="start" fill="currentColor">le="0.5"</text><rect x="118" y="58" width="34" height="30" rx="2" fill="#fde68a" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="155" y="58" width="34" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="192" y="58" width="34" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="229" y="58" width="34" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="266" y="58" width="34" height="30" rx="2" fill="#fde68a" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="303" y="58" width="34" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="340" y="58" width="34" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="377" y="58" width="34" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="414" y="58" width="34" height="30" rx="2" fill="#fde68a" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="451" y="58" width="34" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="488" y="58" width="34" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="525" y="58" width="34" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<text x="12" y="112" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13.5" font-weight="normal" text-anchor="start" fill="currentColor">le="0.1"</text><rect x="118" y="92" width="34" height="30" rx="2" fill="#ea580c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="155" y="92" width="34" height="30" rx="2" fill="#ea580c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="192" y="92" width="34" height="30" rx="2" fill="#ea580c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="229" y="92" width="34" height="30" rx="2" fill="#ea580c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="266" y="92" width="34" height="30" rx="2" fill="#ea580c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="303" y="92" width="34" height="30" rx="2" fill="#ea580c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="340" y="92" width="34" height="30" rx="2" fill="#ea580c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="377" y="92" width="34" height="30" rx="2" fill="#ea580c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="414" y="92" width="34" height="30" rx="2" fill="#ea580c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="451" y="92" width="34" height="30" rx="2" fill="#ea580c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="488" y="92" width="34" height="30" rx="2" fill="#ea580c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="525" y="92" width="34" height="30" rx="2" fill="#ea580c" stroke="currentColor" stroke-opacity="0.18"/>
<text x="12" y="146" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13.5" font-weight="normal" text-anchor="start" fill="currentColor">le="0.05"</text><rect x="118" y="126" width="34" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="155" y="126" width="34" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="192" y="126" width="34" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="229" y="126" width="34" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="266" y="126" width="34" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="303" y="126" width="34" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="340" y="126" width="34" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="377" y="126" width="34" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="414" y="126" width="34" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="451" y="126" width="34" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="488" y="126" width="34" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="525" y="126" width="34" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<text x="12" y="180" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13.5" font-weight="normal" text-anchor="start" fill="currentColor">le="0.01"</text><rect x="118" y="160" width="34" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="155" y="160" width="34" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="192" y="160" width="34" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="229" y="160" width="34" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="266" y="160" width="34" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="303" y="160" width="34" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="340" y="160" width="34" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="377" y="160" width="34" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="414" y="160" width="34" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="451" y="160" width="34" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="488" y="160" width="34" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="525" y="160" width="34" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<text x="12" y="214" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13.5" font-weight="normal" text-anchor="start" fill="currentColor">le="0.005"</text><rect x="118" y="194" width="34" height="30" rx="2" fill="#b91c1c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="155" y="194" width="34" height="30" rx="2" fill="#b91c1c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="192" y="194" width="34" height="30" rx="2" fill="#b91c1c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="229" y="194" width="34" height="30" rx="2" fill="#b91c1c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="266" y="194" width="34" height="30" rx="2" fill="#b91c1c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="303" y="194" width="34" height="30" rx="2" fill="#b91c1c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="340" y="194" width="34" height="30" rx="2" fill="#b91c1c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="377" y="194" width="34" height="30" rx="2" fill="#b91c1c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="414" y="194" width="34" height="30" rx="2" fill="#b91c1c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="451" y="194" width="34" height="30" rx="2" fill="#b91c1c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="488" y="194" width="34" height="30" rx="2" fill="#b91c1c" stroke="currentColor" stroke-opacity="0.18"/>
<rect x="525" y="194" width="34" height="30" rx="2" fill="#b91c1c" stroke="currentColor" stroke-opacity="0.18"/>
<text x="118" y="42" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="12.5" font-weight="normal" text-anchor="start" fill="currentColor" opacity="0.75">temps →</text><path d="M118,92 L155,89 L192,94 L229,90 L266,95 L303,91 L340,94 L377,89 L414,92 L451,94 L488,90 L525,92" fill="none" stroke="#8b5cf6" stroke-width="3"/>
<text x="566" y="85" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="14" font-weight="700" text-anchor="start" fill="#8b5cf6">p95</text><line x1="566" y1="107" x2="620" y2="107" stroke="currentColor" stroke-width="1.5" stroke-dasharray="4 4" opacity="0.6"/>
<text x="628" y="102" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="14" font-weight="600" text-anchor="start" fill="currentColor">réponses calculées</text><text x="628" y="120" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="12.5" font-weight="normal" text-anchor="start" fill="currentColor" opacity="0.75">~100 ms</text><line x1="566" y1="209" x2="620" y2="209" stroke="currentColor" stroke-width="1.5" stroke-dasharray="4 4" opacity="0.6"/>
<text x="628" y="204" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="14" font-weight="600" text-anchor="start" fill="currentColor">réponses servies par le cache</text><text x="628" y="222" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="12.5" font-weight="normal" text-anchor="start" fill="currentColor" opacity="0.75">~5 ms — le gros du trafic</text><text x="12" y="268" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="13" font-weight="normal" text-anchor="start" fill="currentColor" opacity="0.85">Deux bandes nettes : deux populations. Le p95, lui, est une ligne plate au-dessus de la bande haute.</text></svg>

Le p95 correspondant est une courbe plate au-dessus de la bande du haut : il ne laisse jamais deviner qu'il y a deux bandes. Et le jour où le cache se dégrade, la bande du bas maigrit **avant** que le p95 ne bouge vraiment — la masse se déplace bien avant la queue. La heatmap est donc le signal le plus précoce des deux.

## 3. Le p95, déduit de la même colonne

Reprenons la colonne de l'instant t. Le seau `+Inf` donne le total : **10 req/s**. Le p95, c'est le seuil sous lequel passent 95 % d'entre elles, soit **9,5 req/s**. Il suffit de remonter la colonne en cumulant jusqu'à atteindre ce nombre :

<svg viewBox="0 0 920 500" width="100%" role="img" aria-label="Le p95 lu dans la colonne de la heatmap, puis interpole dans le seau" style="max-width:920px;height:auto;display:block;margin:1.2rem auto">
<defs><marker id="ar2b" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="#8b5cf6"/></marker></defs>
<text x="12" y="26" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="15" font-weight="600" text-anchor="start" fill="currentColor">① La colonne de l’instant t</text><text x="268" y="26" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="15" font-weight="600" text-anchor="start" fill="currentColor">② Cumul en partant du bas</text><text x="268" y="46" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="12.5" font-weight="normal" text-anchor="start" fill="currentColor" opacity="0.75">req/s passées sous ce seuil</text><text x="12" y="96" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13.5" font-weight="normal" text-anchor="start" fill="currentColor">le="+Inf"</text><rect x="150" y="76" width="86" height="30" rx="2" fill="#fef3c7" stroke="currentColor" stroke-opacity="0.18"/>
<line x1="244" y1="92" x2="300" y2="92" stroke="currentColor" stroke-width="1" stroke-dasharray="3 3" opacity="0.3"/>
<text x="360" y="96" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="14" font-weight="600" text-anchor="end" fill="currentColor">10,0</text><text x="12" y="130" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13.5" font-weight="normal" text-anchor="start" fill="currentColor">le="0.1"</text><rect x="150" y="110" width="86" height="30" rx="2" fill="#fde68a" stroke="currentColor" stroke-opacity="0.18"/>
<line x1="244" y1="126" x2="300" y2="126" stroke="currentColor" stroke-width="1" stroke-dasharray="3 3" opacity="0.3"/>
<text x="360" y="130" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="14" font-weight="600" text-anchor="end" fill="currentColor">9,9</text><text x="12" y="164" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13.5" font-weight="normal" text-anchor="start" fill="currentColor">le="0.075"</text><rect x="150" y="144" width="86" height="30" rx="2" fill="#fbbf24" stroke="currentColor" stroke-opacity="0.18"/>
<line x1="244" y1="160" x2="300" y2="160" stroke="currentColor" stroke-width="1" stroke-dasharray="3 3" opacity="0.3"/>
<text x="360" y="164" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="14" font-weight="600" text-anchor="end" fill="currentColor">9,7</text><text x="12" y="198" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13.5" font-weight="normal" text-anchor="start" fill="currentColor">le="0.05"</text><rect x="150" y="178" width="86" height="30" rx="2" fill="#ea580c" stroke="currentColor" stroke-opacity="0.18"/>
<line x1="244" y1="194" x2="300" y2="194" stroke="currentColor" stroke-width="1" stroke-dasharray="3 3" opacity="0.3"/>
<text x="360" y="198" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="14" font-weight="600" text-anchor="end" fill="currentColor">9,2</text><text x="12" y="232" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13.5" font-weight="normal" text-anchor="start" fill="currentColor">le="0.025"</text><rect x="150" y="212" width="86" height="30" rx="2" fill="#b91c1c" stroke="currentColor" stroke-opacity="0.18"/>
<line x1="244" y1="228" x2="300" y2="228" stroke="currentColor" stroke-width="1" stroke-dasharray="3 3" opacity="0.3"/>
<text x="360" y="232" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="14" font-weight="600" text-anchor="end" fill="currentColor">7,0</text><text x="12" y="266" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13.5" font-weight="normal" text-anchor="start" fill="currentColor">le="0.01"</text><rect x="150" y="246" width="86" height="30" rx="2" fill="#ea580c" stroke="currentColor" stroke-opacity="0.18"/>
<line x1="244" y1="262" x2="300" y2="262" stroke="currentColor" stroke-width="1" stroke-dasharray="3 3" opacity="0.3"/>
<text x="360" y="266" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="14" font-weight="600" text-anchor="end" fill="currentColor">3,0</text><text x="12" y="300" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13.5" font-weight="normal" text-anchor="start" fill="currentColor">le="0.005"</text><rect x="150" y="280" width="86" height="30" rx="2" fill="#f59e0b" stroke="currentColor" stroke-opacity="0.18"/>
<line x1="244" y1="296" x2="300" y2="296" stroke="currentColor" stroke-width="1" stroke-dasharray="3 3" opacity="0.3"/>
<text x="360" y="300" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="14" font-weight="600" text-anchor="end" fill="currentColor">1,0</text><rect x="146" y="140" width="94" height="38" fill="none" stroke="#8b5cf6" stroke-width="2.5" rx="4"/>
<line x1="380" y1="159" x2="424" y2="159" stroke="#8b5cf6" stroke-width="2" marker-end="url(#ar2b)"/>
<text x="436" y="148" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="15.5" font-weight="700" text-anchor="start" fill="#8b5cf6">95 % de 10,0 req/s = 9,5</text><text x="436" y="170" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="13.5" font-weight="normal" text-anchor="start" fill="currentColor">9,2 &lt; 9,5 ≤ 9,7 : le p95 tombe dans ce seau,</text><text x="436" y="190" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="13.5" font-weight="normal" text-anchor="start" fill="currentColor">quelque part entre 50 ms et 75 ms.</text><line x1="150" y1="180" x2="150" y2="408" stroke="#8b5cf6" stroke-width="1.4" stroke-dasharray="4 4" opacity="0.75"/>
<line x1="240" y1="180" x2="780" y2="408" stroke="#8b5cf6" stroke-width="1.4" stroke-dasharray="4 4" opacity="0.75"/>
<text x="12" y="366" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="15" font-weight="600" text-anchor="start" fill="currentColor">③ Interpolation : on suppose les requêtes régulièrement réparties dans le seau</text><rect x="150" y="410" width="630" height="28" rx="4" fill="currentColor" fill-opacity="0.07" stroke="currentColor" stroke-opacity="0.25"/>
<rect x="150" y="410" width="378" height="28" rx="4" fill="#8b5cf6" fill-opacity="0.22"/>
<line x1="528" y1="398" x2="528" y2="442" stroke="#8b5cf6" stroke-width="3"/>
<text x="528" y="390" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="15.5" font-weight="700" text-anchor="middle" fill="#8b5cf6">p95 = 65 ms</text><text x="150" y="462" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="14" font-weight="normal" text-anchor="start" fill="currentColor">50 ms</text><text x="150" y="480" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="12.5" font-weight="normal" text-anchor="start" fill="currentColor" opacity="0.75">9,2 req/s cumulées</text><text x="780" y="462" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="14" font-weight="normal" text-anchor="end" fill="currentColor">75 ms</text><text x="780" y="480" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="12.5" font-weight="normal" text-anchor="end" fill="currentColor" opacity="0.75">9,7 req/s cumulées</text><text x="339" y="430" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="13.5" font-weight="600" text-anchor="middle" fill="currentColor">60 % du seau</text><text x="339" y="462" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="13" font-weight="normal" text-anchor="middle" fill="currentColor" opacity="0.85">(9,5 − 9,2) / (9,7 − 9,2) = 0,6</text></svg>

Deux lectures, et le résultat tombe :

1. **Trouver le bon seau.** Le cumul vaut 9,2 sous 50 ms et 9,7 sous 75 ms. La cible, 9,5, est entre les deux : le p95 est dans le seau (50 ms ; 75 ms].
2. **Interpoler dedans.** Il manque 0,3 req/s sur les 0,5 que contient ce seau, soit **60 %** du chemin. Prometheus applique cette proportion à la **largeur** du seau : 50 + 0,6 × (75 − 50) = **65 ms**.

C'est exactement ce que calcule la fonction `histogram_quantile`, et c'est pourquoi la requête du panel voisin est **la requête de la heatmap avec un étage de plus** :

```promql
# la heatmap : toute la distribution
sum by(le) (rate(app_cart_add_item_latency_seconds_bucket[$__rate_interval]))

# le p95 : la même chose, résumée en un point par instant
histogram_quantile(0.95, sum by(le) (rate(app_cart_add_item_latency_seconds_bucket[$__rate_interval])))
```

> 🔑 **Le p95 est ce qui reste de la heatmap quand on n'en garde qu'une valeur par colonne.** Même métrique, même `rate`, même `sum by(le)` — deux lectures.

**Pourquoi des seaux plutôt que des durées.** Parce qu'**un percentile ne s'additionne pas**. La moyenne du p95 de deux pods n'est pas le p95 de l'ensemble, c'est un nombre sans signification. Des seaux, eux, s'additionnent sans difficulté : 120 requêtes sous 10 ms ici, 200 là, cela fait bien 320 — c'est tout ce que fait le `sum by(le)`. On renonce donc aux durées exactes pour gagner le droit d'agréger, quitte à recalculer le percentile au moment de l'affichage.

*« Et pourquoi ne pas trier les requêtes dans Jaeger et lire celle qui tombe au 95ᵉ centile, tout simplement ? »* Parce qu'elle n'y est peut-être pas — au Lab 7, le tail sampling ne gardera qu'un quart des traces — et parce qu'un service réel produit des millions de requêtes par minute : les trier à chaque rafraîchissement du panel, sur six heures de fenêtre, n'est pas tenable. Les traces vivent d'ailleurs quelques jours, les métriques des mois. Chaque signal fait son métier : la métrique dit **qu'il y a** un problème et depuis quand, pour trois fois rien et sur la longue durée ; la trace dit **laquelle** des requêtes a souffert.

## 4. La limite du p95 : la largeur du seau

**Sa précision est celle du seau.** Les 65 ms du schéma ne sont pas une mesure : les 0,5 req/s de ce seau pourraient aussi bien être toutes à 51 ms que toutes à 74 ms, la réponse serait la même. « 65 ms » signifie surtout « entre 50 et 75 ». Seuls des seaux plus serrés améliorent la précision, et cela se règle à la production de la métrique, pas à la lecture.

## 5. Heatmap ou percentile ?

| | Heatmap | Percentile |
|---|---|---|
| Répond à | « à quoi ressemble la distribution ? » | « ça va, ou pas ? » |
| Bonne pour | comprendre, explorer un incident | suivre dans le temps, **alerter** |
| Faiblesse | dense, illisible sur une longue fenêtre ; aucun seuil à y poser | masque la forme de la distribution |

Une alerte a besoin d'un nombre unique à comparer à un seuil : c'est le p95, pas la heatmap. Mais quand l'alerte a sonné, c'est la heatmap qu'on regarde pour savoir **ce qui s'est déplacé**.

## 6. Quand le dashboard invente un pic

Un dernier détour, sur la même requête. Le Lab 4 posait une règle sans la démontrer — **toujours `rate` d'abord, `sum` ensuite** — et voici pourquoi, sur un incident que tous les clusters connaissent : le redémarrage d'un pod.

Deux pods de collecteur, `A` et `B`, 2 requêtes/s chacun — donc **4 req/s en réalité**, stable. Scrape toutes les 15 s. `B` redémarre à t=45 s.

<svg viewBox="0 0 920 486" width="100%" role="img" aria-label="Le pic fantome : un pod qui redemarre, vu par sum(rate) et par rate(sum)" style="max-width:920px;height:auto;display:block;margin:1.2rem auto">
<defs><marker id="ph" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6" markerHeight="6" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="#dc2626"/></marker></defs>
<text x="14" y="24" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="15.5" font-weight="700" text-anchor="start" fill="currentColor">Ce que Prometheus scrape : deux compteurs, dont l’un repart de zéro</text><line x1="80" y1="176" x2="890" y2="176" stroke="currentColor" stroke-width="1.2" opacity="0.35"/>
<line x1="96" y1="176" x2="96" y2="181" stroke="currentColor" stroke-width="1.2" opacity="0.35"/>
<text x="96" y="197" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="12.5" font-weight="normal" text-anchor="middle" fill="currentColor" opacity="0.8">0 s</text><line x1="246" y1="176" x2="246" y2="181" stroke="currentColor" stroke-width="1.2" opacity="0.35"/>
<text x="246" y="197" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="12.5" font-weight="normal" text-anchor="middle" fill="currentColor" opacity="0.8">15 s</text><line x1="396" y1="176" x2="396" y2="181" stroke="currentColor" stroke-width="1.2" opacity="0.35"/>
<text x="396" y="197" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="12.5" font-weight="normal" text-anchor="middle" fill="currentColor" opacity="0.8">30 s</text><line x1="546" y1="176" x2="546" y2="181" stroke="currentColor" stroke-width="1.2" opacity="0.35"/>
<text x="546" y="197" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="12.5" font-weight="normal" text-anchor="middle" fill="currentColor" opacity="0.8">45 s</text><line x1="696" y1="176" x2="696" y2="181" stroke="currentColor" stroke-width="1.2" opacity="0.35"/>
<text x="696" y="197" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="12.5" font-weight="normal" text-anchor="middle" fill="currentColor" opacity="0.8">60 s</text><line x1="546" y1="44" x2="546" y2="182" stroke="#dc2626" stroke-width="1.6" stroke-dasharray="5 4"/>
<text x="552" y="56" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="13.5" font-weight="700" text-anchor="start" fill="#dc2626">B redémarre</text><polyline points="96,83 246,80 396,77 546,74 696,71" fill="none" stroke="#3b82f6" stroke-width="2.8"/>
<polyline points="96,101 246,99 396,96 516,93" fill="none" stroke="#10b981" stroke-width="2.8"/>
<polyline points="516,93 516,176" fill="none" stroke="#10b981" stroke-width="2.4" stroke-dasharray="4 3"/>
<polyline points="546,176 696,173" fill="none" stroke="#10b981" stroke-width="2.8"/>
<circle cx="96" cy="83" r="3.6" fill="#3b82f6"/>
<circle cx="246" cy="80" r="3.6" fill="#3b82f6"/>
<circle cx="396" cy="77" r="3.6" fill="#3b82f6"/>
<circle cx="546" cy="74" r="3.6" fill="#3b82f6"/>
<circle cx="696" cy="71" r="3.6" fill="#3b82f6"/>
<circle cx="96" cy="101" r="3.6" fill="#10b981"/>
<circle cx="246" cy="99" r="3.6" fill="#10b981"/>
<circle cx="396" cy="96" r="3.6" fill="#10b981"/>
<circle cx="546" cy="176" r="3.6" fill="#10b981"/>
<circle cx="696" cy="173" r="3.6" fill="#10b981"/>
<text x="712" y="76.46666666666667" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="13.5" font-weight="700" text-anchor="start" fill="#3b82f6">pod A</text><text x="712" y="178.2" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="13.5" font-weight="700" text-anchor="start" fill="#10b981">pod B</text><text x="538" y="64.26666666666667" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="12.5" font-weight="700" text-anchor="end" fill="#3b82f6">1090</text><text x="538" y="170" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="13" font-weight="700" text-anchor="end" fill="#10b981">0</text><text x="14" y="218" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="13" font-weight="normal" text-anchor="start" fill="currentColor" opacity="0.85">Les deux pods servent 2 req/s chacun : le trafic réel vaut 4 req/s, du début à la fin.</text><rect x="14" y="244" width="438" height="168" rx="6" fill="none" stroke="currentColor" stroke-opacity="0.28"/>
<text x="30" y="272" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="15" font-weight="700" text-anchor="start" fill="#10b981">sum(rate(...))</text><text x="30" y="292" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="12.5" font-weight="normal" text-anchor="start" fill="currentColor" opacity="0.8">rate corrige chaque pod séparément</text><line x1="72" y1="388" x2="436" y2="388" stroke="currentColor" stroke-width="1" stroke-dasharray="3 3" opacity="0.3"/>
<text x="64" y="392" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="12" font-weight="normal" text-anchor="end" fill="currentColor" opacity="0.8">4/s</text><rect x="468" y="244" width="438" height="168" rx="6" fill="none" stroke="currentColor" stroke-opacity="0.28"/>
<text x="484" y="272" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="15" font-weight="700" text-anchor="start" fill="#dc2626">rate(sum(...))</text><text x="484" y="292" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="12.5" font-weight="normal" text-anchor="start" fill="currentColor" opacity="0.8">la baisse du total est prise pour un reset</text><line x1="526" y1="388" x2="890" y2="388" stroke="currentColor" stroke-width="1" stroke-dasharray="3 3" opacity="0.3"/>
<text x="518" y="392" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="12" font-weight="normal" text-anchor="end" fill="currentColor" opacity="0.8">4/s</text><polyline points="72,388 200,388 250,388 268,400 310,400 328,388 436,388" fill="none" stroke="#10b981" stroke-width="3"/>
<text x="289" y="418" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="12.5" font-weight="700" text-anchor="middle" fill="#10b981">2/s</text><polyline points="526,388 660,388 700,388" fill="none" stroke="#dc2626" stroke-width="3"/>
<polyline points="700,388 730,322" fill="none" stroke="#dc2626" stroke-width="3" marker-end="url(#ph)"/>
<polyline points="734,322 764,388 890,388" fill="none" stroke="#dc2626" stroke-width="3"/>
<text x="732" y="310" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="14.5" font-weight="700" text-anchor="middle" fill="#dc2626">≈ 73/s</text><text x="14" y="442" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="13.5" font-weight="600" text-anchor="start" fill="currentColor">Le creux est la vérité : la moitié de la</text><text x="14" y="462" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="13.5" font-weight="600" text-anchor="start" fill="currentColor">capacité était absente pendant 15 s.</text><text x="468" y="442" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="13.5" font-weight="600" text-anchor="start" fill="currentColor">Un pic de trafic au moment précis où un</text><text x="468" y="462" font-family="system-ui, -apple-system, Segoe UI, Roboto, sans-serif" font-size="13.5" font-weight="600" text-anchor="start" fill="currentColor">pod est mort — et il n’y a eu aucun trafic.</text></svg>

| t | A | rate(A) | B | rate(B) | **sum(rate)** ✅ | A+B | **rate(sum)** ❌ |
|---|---|---|---|---|---|---|---|
| 0 s | 1000 | — | 800 | — | — | 1800 | — |
| 15 s | 1030 | 2/s | 830 | 2/s | **4/s** | 1860 | **4/s** |
| 30 s | 1060 | 2/s | 860 | 2/s | **4/s** | 1920 | **4/s** |
| 45 s | 1090 | 2/s | **0** ⚡ | 0/s | **2/s** | **1090** | **≈ 73/s** 💥 |
| 60 s | 1120 | 2/s | 30 | 2/s | **4/s** | 1150 | **4/s** |

Les deux écritures donnent le même résultat partout, **sauf sur la ligne du redémarrage**.

À gauche, `rate` compare 0 à 860 sur la seule série de `B` : reset reconnu, delta ramené à 0 — le pod n'a effectivement rien compté pendant qu'il redémarrait. La courbe creuse à 2/s, ce qui est la vérité : la moitié de la capacité était absente.

À droite, la même comparaison se fait sur le total, 1090 contre 1920. Baisse, donc reset, donc delta = 1090 → `1090 / 15 ≈ 73/s`. Ce 1090, ce sont les **requêtes cumulées de `A` depuis son propre démarrage**, comptées d'un coup comme si elles venaient d'arriver en 15 secondes. Le pic n'est pas du trafic : c'est l'historique de `A` relâché sur un intervalle. Et plus `A` tourne depuis longtemps, pire c'est — à 50 000 au compteur, le faux pic monterait à 3 300/s.

Deux détails que le tableau simplifie : un vrai `rate[2m]` étale ce pic sur la fenêtre au lieu de le concentrer sur un point (plus bas, plus large, même erreur totale) ; et PromQL rend d'ailleurs la mauvaise écriture malaisée — `rate(sum(...)[2m])` est invalide, il faut une *subquery* pour y arriver.

Cette écriture-là, PromQL la rend d'ailleurs difficile à commettre. Ce qui se transpose, c'est le réflexe : **un pic sur un dashboard peut être un artefact du calcul et pas un événement**. Devant une valeur spectaculaire, la première question à se poser est de savoir si elle décrit le système ou la façon dont on l'interroge.
