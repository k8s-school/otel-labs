---
title: 'Lab 8 — Sécurité & conformité : masquer les données sensibles'
date: 2026-07-06T16:20:00+02:00
draft: false
weight: 80
tags: ["OpenTelemetry", "sécurité", "RGPD", "PII", "OTTL"]
---

La télémétrie est un **canal de fuite** : tokens, mots de passe, emails s'y retrouvent trop facilement — et un backend d'observabilité est rarement protégé comme la base de production. Dans ce lab, vous **constatez une fuite réelle** (déjà dans le code de `review-service`...), puis vous la neutralisez à **deux niveaux** : dans le SDK de l'application et, en filet de sécurité, dans le collecteur.

> 🇪🇺 **RGPD** : email, nom, téléphone sont des **données personnelles**. Leur présence dans les traces/logs crée les mêmes obligations (droit à l'effacement, rétention...) que dans une base — dans un système conçu pour tout garder.

## Prérequis

* Labs 1 à 7 terminés.
* **D'abord** les variables de la formation chargées dans votre shell : `. ./scripts/env.sh`. Elles donnent le port du review-service (`$APP_PORT`, accès **direct** au service, pas via le frontend-proxy) et `$PF_HOST`, le nom par lequel vous le joignez.
* Les accès ouverts (`./scripts/open-ui.sh`) : l'API OpenSearch est sur `http://$PF_HOST:$OS_PORT/`.

## Étapes

### Partie 1 — Constater la fuite

1.  **Relire le code du POST** dans `ReviewController.java` — trois fautes y sont plantées volontairement :

```java
span.setAttribute("user.email", ...);                                  // PII dans un attribut de span
span.setAttribute("http.request.header.authorization", authorization); // credentials dans un span !
logger.info("Creating review for product {} by {} <{}>", ...);         // PII dans un log
```

2.  **Déployer avec le Starter** (nécessaire pour la partie SDK) et générer une requête « authentifiée » :

```bash
. ./scripts/env.sh   # si ce n'est pas déjà fait dans ce terminal
./scripts/deploy.sh -p starter
curl -X POST http://$PF_HOST:$APP_PORT/api/reviews \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.SECRET-JWT-TOKEN" \
  -d '{"productId": "OLJCESPC7Z", "rating": 5, "comment": "fuite", "userEmail": "leak@example.com", "userName": "Leaky User"}'
```

3.  **Chercher la fuite.** Dans Jaeger, ouvrez la trace `POST /api/reviews` : que voyez-vous dans les attributs ? Dans Grafana/OpenSearch, cherchez `leak@example.com`.

{{%expand "Réponse" %}}
* Span `POST /api/reviews` → attributs `user.email = leak@example.com` et `http.request.header.authorization = Bearer eyJ...` : **le token JWT complet est dans Jaeger**. Quiconque accède à l'UI peut le rejouer.
* OpenSearch → le log `Creating review for product ... by Leaky User <leak@example.com>` : PII indexée, requêtable, sauvegardée.

Fuites typiques du même genre : payloads complets en attribut, URLs avec `?token=...` (`url.full`), headers `Cookie`, corps d'exceptions avec mots de passe.
{{% /expand%}}

### Partie 2 — Masquer dans le SDK (au plus près de la source)

4.  **Lire le mécanisme** dans `PiiMaskingConfiguration.java` et `PiiRedactingLogRecordExporter.java` : un décorateur d'exporter qui remplace les emails du body par `***@***`, branché sur le SDK du Starter via `AutoConfigurationCustomizerProvider`, activé par la variable `MASK_PII`.

> Pourquoi pas un `LogRecordProcessor` ? Dans l'API stable, `onEmit` peut modifier les **attributs** (`setAttribute`) mais pas le **body** — d'où le wrapper d'exporter. Un `SpanProcessor` a la même limite en `onEnd` (span en lecture seule) : côté spans, le SDK filtre à la source (`Sampler`, ne pas poser l'attribut !) et la réécriture se fait au collecteur.

5.  **Activer le masquage SDK et rejouer :**

```bash
kubectl set env -n otel-demo deployment/review-service MASK_PII=true
kubectl rollout status -n otel-demo deployment/review-service
curl -X POST http://$PF_HOST:$APP_PORT/api/reviews \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.SECRET-JWT-TOKEN" \
  -d '{"productId": "OLJCESPC7Z", "rating": 5, "comment": "sdk-mask", "userEmail": "sdk-mask@example.com", "userName": "Masked User"}'
```

Vérifiez : le **log** est masqué (`***@***` dans OpenSearch)... mais les **attributs du span** fuient toujours dans Jaeger !

### Partie 3 — Le filet de sécurité : masquer au collecteur

6.  **Écrire la règle OTTL** dans `manifests/80-otel-security-values.yaml` : elle supprime `user.email` et `http.request.header.authorization` de **tous** les spans, et masque les emails dans **tous** les bodies de logs — quel que soit le service, corrigé ou non.

    Deux documentations pour cela : celle du [processor `transform`](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/transformprocessor/README.md), qui donne la structure (`trace_statements`, `log_statements`), et la [liste des fonctions OTTL](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/pkg/ottl/ottlfuncs/README.md) — `delete_key` et `replace_pattern` sont celles qu'il vous faut.

{{%expand "Réponse" %}}
Fichier de référence [`80-otel-security-values.yaml`](../80-otel-security-values.yaml). Pour l'utiliser tel quel :

```bash
cp content/1_Labs/80-otel-security-values.yaml manifests/
```

Son contenu :

```yaml
opentelemetry-collector:
  config:
    processors:
      transform/pii-spans:
        error_mode: ignore
        trace_statements:
          - context: span
            statements:
              - delete_key(span.attributes, "user.email")
              - delete_key(span.attributes, "http.request.header.authorization")
      transform/pii-logs:
        error_mode: ignore
        log_statements:
          - context: log
            statements:
              - replace_pattern(log.body, "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+", "***@***")
    service:
      pipelines:
        traces:
          processors: [memory_limiter, resourcedetection, resource, transform, transform/pii-spans, tail_sampling, batch]
        logs:
          processors: [memory_limiter, resourcedetection, resource, transform/pii-logs, batch]
```

Alternatives : le processor **`redaction`** (approche *allowlist* : seuls les attributs autorisés passent — plus sûr qu'une denylist) et `replace_pattern(..., hash=...)` pour **pseudonymiser** (hachage) au lieu de supprimer, quand on veut garder la capacité de corréler.
{{% /expand%}}

7.  **Appliquer et vérifier l'avant/après :**

```bash
helm upgrade otel-demo open-telemetry/opentelemetry-demo \
  --version 0.40.9 -n otel-demo \
  -f manifests/values-training.yaml \
  -f manifests/30-otel-collector-values.yaml \
  -f manifests/60-otel-metrics-values.yaml \
  -f manifests/70-otel-traces-values.yaml \
  -f manifests/80-otel-security-values.yaml
kubectl rollout status daemonset/otel-collector-agent -n otel-demo

# on peut même désactiver le masquage SDK : le collecteur protège seul
kubectl set env -n otel-demo deployment/review-service MASK_PII-
kubectl rollout status -n otel-demo deployment/review-service
# rejouer un POST avec un email marqueur :
curl -X POST http://$PF_HOST:$APP_PORT/api/reviews \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.SECRET-JWT-TOKEN" \
  -d '{"productId": "OLJCESPC7Z", "rating": 5, "comment": "collector-mask", "userEmail": "collector-mask@example.com", "userName": "Safe User"}'
```

Dans Jaeger : la nouvelle trace `POST /api/reviews` n'a **plus** ni `user.email` ni le header `Authorization`. Dans OpenSearch : `collector-mask@example.com` est introuvable, le log montre `***@***`.

8.  **La vraie correction :** le masquage en aval est un **filet**, pas une excuse — la faute reste dans le code. Supprimez les trois lignes fautives de `ReviewController.java` (masquage **applicatif**, niveau 1 de la défense en profondeur) et gardez les règles collecteur pour les services que vous ne contrôlez pas.

## Livrable

La preuve **avant / après** : capture de la trace avec JWT + email (partie 1) et de la même requête après masquage (partie 3), plus la recherche OpenSearch vide sur l'email marqueur.
