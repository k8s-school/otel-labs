---
title: 'Lab 8 — Sécurité & conformité : masquer les données sensibles'
date: 2026-07-06T16:20:00+02:00
draft: false
weight: 80
tags: ["OpenTelemetry", "sécurité", "RGPD", "PII", "OTTL"]
---

La télémétrie est un **canal de fuite** : tokens, mots de passe, emails s'y retrouvent trop facilement — et un backend d'observabilité est rarement protégé comme la base de production. Dans ce lab, vous **constatez une fuite réelle** (déjà dans le code de `review-service`...), vous la **corrigez là où elle naît**, puis vous posez un **filet** dans le collecteur pour tout ce que votre correction ne peut pas atteindre.

> 🇪🇺 **RGPD** : email, nom, téléphone sont des **données personnelles**. Leur présence dans les traces et les logs crée exactement les mêmes obligations que dans une base de données : droit à l'effacement, durée de conservation limitée, traçabilité des accès.
>
> Sauf qu'une plateforme d'observabilité est bâtie pour l'inverse. Elle **duplique** — le même email part dans Jaeger, dans OpenSearch, dans les dashboards exportés et dans les sauvegardes — et elle **conserve**, sans rien savoir de ce qu'elle stocke. Effacer une donnée d'une base, c'est une requête ; l'effacer de six mois de traces réparties sur trois backends, personne ne sait le faire proprement.
>
> D'où la seule stratégie tenable, et l'objet de ce lab : **ne jamais l'y envoyer**.

## Prérequis

* Labs 1 à 7 terminés, agent Java actif sur `review-service` — l'application reste exactement celle du Lab 7, ce lab ne la redéploie qu'après l'avoir corrigée.
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

2.  **Générer une requête « authentifiée »** — sur l'application du Lab 7, telle quelle, agent Java compris. Rien à redéployer :

```bash
. ./scripts/env.sh   # si ce n'est pas déjà fait dans ce terminal
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

### Partie 2 — Corriger là où la fuite naît

4.  **Supprimer les trois lignes fautives** de `ReviewController.java`. Une fuite écrite par votre propre code n'a qu'une seule vraie correction : ne pas l'écrire.

```java
// AVANT — trois fautes
Span span = Span.current();
span.setAttribute("user.email", String.valueOf(review.getUserEmail()));
if (authorization != null) {
    span.setAttribute("http.request.header.authorization", authorization);
}
logger.info("Creating review for product {} by {} <{}>",
        review.getProductId(), review.getUserName(), review.getUserEmail());

// APRÈS — le log garde ce qui sert au diagnostic, et rien de plus
logger.info("Creating review for product {}", review.getProductId());
```

L'identifiant produit reste : il est utile en cas d'incident et n'identifie personne. Ce qui part, c'est ce qui n'aurait jamais dû être écrit.

5.  **Reconstruire et rejouer** avec un nouvel email marqueur :

```bash
./scripts/deploy.sh
# deploy.sh repart du manifeste : il faut réactiver l'agent, comme au Lab 5
kubectl set env -n otel-demo deployment/review-service \
  JAVA_TOOL_OPTIONS="-javaagent:/otel/opentelemetry-javaagent.jar"
kubectl rollout status -n otel-demo deployment/review-service

curl -X POST http://$PF_HOST:$APP_PORT/api/reviews \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.SECRET-JWT-TOKEN" \
  -d '{"productId": "OLJCESPC7Z", "rating": 5, "comment": "fixed", "userEmail": "fixed@example.com", "userName": "Fixed User"}'
```

> ⚠️ **Sans ces deux lignes, vous ne verriez plus rien du tout** — et vous croiriez la fuite corrigée. `deploy.sh` réapplique le manifeste, qui ne contient pas `JAVA_TOOL_OPTIONS` : l'agent redevient inactif, l'application cesse d'émettre, et Jaeger reste vide pour de mauvaises raisons. Le réflexe du Lab 4 s'applique : une absence de télémétrie se vérifie avant de se célébrer.

Dans Jaeger, la nouvelle trace `POST /api/reviews` n'a plus ni `user.email` ni le header `Authorization`. Dans OpenSearch, `fixed@example.com` est introuvable.

> 💡 **Alors pourquoi une partie 3 ?** Parce que cette correction ne couvre **que le code que vous écrivez**. Trois choses lui échappent, et elles sont la règle en production :
>
> * **Les services que vous ne contrôlez pas.** Les onze autres services de la démo, une bibliothèque tierce, l'équipe d'à côté qui n'a pas encore fait ce lab.
> * **L'instrumentation automatique elle-même.** L'agent pose `url.full` — qui contient le `?token=…` d'un appel sortant —, `db.statement`, des en-têtes HTTP que vous n'avez pas choisis. Aucune ligne de votre code n'est en cause.
> * **La régression.** Un `setAttribute` fautif revient dans six mois, dans une revue de code que personne ne relie à la RGPD.
>
> D'où le second étage. Notez l'ordre : on **corrige**, *puis* on met un filet. L'inverse — masquer en aval et laisser la faute dans le code — revient à faire circuler la PII dans tout le réseau en espérant que le filtre ne tombe jamais.

> 💡 **Et le masquage dans le SDK, entre les deux ?** Il existe, et il a deux justifications précises — ni l'une ni l'autre n'est le cas de ce lab. La première : votre politique interne interdit que la donnée **quitte le processus**, or le collecteur est un autre processus, souvent sur un autre nœud. La seconde : vous voulez filtrer ce que pose l'instrumentation automatique **avant** l'export, sans dépendre d'une configuration de collecteur que vous ne maîtrisez pas.
>
> Le dépôt en garde un exemple fonctionnel, à lire : `PiiMaskingConfiguration.java` et `PiiRedactingLogRecordExporter.java` — un décorateur d'exporter qui remplace les emails du body par `***@***`, activé par la variable `MASK_PII`. Deux détails valent le détour. D'abord, c'est un **décorateur d'exporter** et pas un `LogRecordProcessor` : dans l'API stable, `onEmit` peut modifier les **attributs** mais pas le **body**. Ensuite, ce code n'a d'effet **qu'avec le Starter** du Lab 2 : c'est un bean Spring, et l'agent Java — celui que vous utilisez depuis le Lab 2 — initialise son propre SDK avant Spring, dans un classloader isolé. Côté agent, le même filtrage demanderait une [extension](https://opentelemetry.io/docs/zero-code/java/agent/extensions/) : le même code, mais dans un JAR séparé chargé par `-Dotel.javaagent.extensions=…`.

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

7.  **Appliquer, puis remettre la faute** — c'est la seule façon de vérifier qu'un filet retient : en tombant dedans. Remettez les trois lignes que vous avez supprimées à l'étape 4 (`git checkout apps/review-service/src/main/java/fr/k8sschool/reviews/ReviewController.java` si vous n'y avez touché qu'ici), reconstruisez, et rejouez la requête fautive.

```bash
helm upgrade otel-demo open-telemetry/opentelemetry-demo \
  --version 0.40.9 -n otel-demo \
  -f manifests/values-training.yaml \
  -f manifests/30-otel-collector-values.yaml \
  -f manifests/60-otel-metrics-values.yaml \
  -f manifests/70-otel-traces-values.yaml \
  -f manifests/80-otel-security-values.yaml
kubectl rollout status daemonset/otel-collector-agent -n otel-demo

# la faute est de retour dans le code, comme si un collègue l'avait réintroduite
git checkout apps/review-service/src/main/java/fr/k8sschool/reviews/ReviewController.java
./scripts/deploy.sh
kubectl set env -n otel-demo deployment/review-service \
  JAVA_TOOL_OPTIONS="-javaagent:/otel/opentelemetry-javaagent.jar"
kubectl rollout status -n otel-demo deployment/review-service

# rejouer un POST avec un email marqueur :
curl -X POST http://$PF_HOST:$APP_PORT/api/reviews \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.SECRET-JWT-TOKEN" \
  -d '{"productId": "OLJCESPC7Z", "rating": 5, "comment": "collector-mask", "userEmail": "collector-mask@example.com", "userName": "Safe User"}'
```

Dans Jaeger : la nouvelle trace `POST /api/reviews` n'a **plus** ni `user.email` ni le header `Authorization`. Dans OpenSearch : `collector-mask@example.com` est introuvable, le log montre `***@***`.

La trace est propre alors que le code est fautif : le filet a retenu. C'est ce que vous voulez le jour où la faute vient d'un service que vous ne pouvez pas corriger.

8.  **Reposer la correction, et la garder.** Le filet n'est pas une excuse : la PII a bel et bien quitté le processus, traversé le réseau, et n'a été arrêtée qu'au collecteur — un maillon qui peut être mal configuré, contourné par un service qui exporte ailleurs, ou remis à zéro par un `helm upgrade` malheureux. Supprimez de nouveau les trois lignes, et laissez les deux étages en place :

```bash
# refaites l'édition de l'étape 4, puis :
./scripts/deploy.sh
kubectl set env -n otel-demo deployment/review-service \
  JAVA_TOOL_OPTIONS="-javaagent:/otel/opentelemetry-javaagent.jar"
kubectl rollout status -n otel-demo deployment/review-service
```

C'est la **défense en profondeur** : le code ne produit plus la donnée, et le collecteur protège ce que le code ne couvre pas.

## Livrable

La preuve **avant / après** : capture de la trace avec JWT + email (partie 1), la même requête après correction du code (partie 2), et la trace propre alors que la faute est de retour (partie 3) — plus la recherche OpenSearch vide sur les emails marqueurs.
