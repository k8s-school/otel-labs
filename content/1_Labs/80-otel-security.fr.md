---
title: 'Lab 8 — Sécurité & conformité : masquer les données sensibles'
date: 2026-07-06T16:20:00+02:00
draft: false
weight: 80
tags: ["OpenTelemetry", "sécurité", "RGPD", "PII", "OTTL"]
---

La télémétrie est un **canal de fuite** : tokens, mots de passe, emails s'y retrouvent trop facilement — et un backend d'observabilité est rarement protégé comme la base de production. Dans ce lab, vous **constatez une fuite réelle** (déjà dans le code de `review-service`...), vous voyez **où elle doit être corrigée**, puis vous posez un **filet** dans le collecteur pour tout ce qu'une correction de code ne peut pas atteindre.

> 🇪🇺 **RGPD** : email, nom, téléphone sont des **données personnelles**. Leur présence dans les traces et les logs crée exactement les mêmes obligations que dans une base de données : droit à l'effacement, durée de conservation limitée, traçabilité des accès.
>
> Sauf qu'une plateforme d'observabilité est bâtie pour l'inverse. Elle **duplique** — le même email part dans Jaeger, dans OpenSearch, dans les dashboards exportés et dans les sauvegardes — et elle **conserve**, sans rien savoir de ce qu'elle stocke. Effacer une donnée d'une base, c'est une requête ; l'effacer de six mois de traces réparties sur trois backends, personne ne sait le faire proprement.
>
> D'où la seule stratégie tenable, et l'objet de ce lab : **ne jamais l'y envoyer**.

## Prérequis

* Labs 1 à 7 terminés, agent Java actif sur `review-service` — l'application reste exactement celle du Lab 7, ce lab ne la reconstruit à aucun moment.
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

4.  **La seule vraie correction : ne pas écrire la donnée.** Une fuite produite par votre propre code se règle dans ce code — trois lignes à supprimer dans `ReviewController.java`, et rien d'autre.

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

> 💡 **Pour le vérifier vous-même** (optionnel — c'est une reconstruction complète de l'image, quelques minutes) :
>
> ```bash
> ./scripts/deploy.sh
> # deploy.sh repart du manifeste, qui ne contient pas JAVA_TOOL_OPTIONS :
> # sans ces deux lignes l'agent reste inactif, l'application n'émet plus rien,
> # et Jaeger paraît propre pour une très mauvaise raison
> kubectl set env -n otel-demo deployment/review-service \
>   JAVA_TOOL_OPTIONS="-javaagent:/otel/opentelemetry-javaagent.jar"
> kubectl rollout status -n otel-demo deployment/review-service
> ```
>
> Rejouez alors le `curl` de l'étape 2 : la trace n'a plus ni `user.email` ni le header `Authorization`, et l'email est introuvable dans OpenSearch.
>
> **La suite du lab garde volontairement le code fautif**, pour que la partie 3 ait quelque chose à retenir.

> 💡 **Alors pourquoi une partie 3 ?** Parce que cette correction ne couvre **que le code que vous écrivez**. Trois choses lui échappent, et elles sont la règle en production :
>
> * **Les services que vous ne contrôlez pas.** Les onze autres services de la démo, une bibliothèque tierce, l'équipe d'à côté qui n'a pas encore fait ce lab.
> * **L'instrumentation automatique elle-même.** L'agent pose `url.full` — qui contient le `?token=…` d'un appel sortant —, `db.statement`, des en-têtes HTTP que vous n'avez pas choisis. Aucune ligne de votre code n'est en cause.
> * **La régression.** Un `setAttribute` fautif revient dans six mois, dans une revue de code que personne ne relie à la RGPD.
>
> D'où le second étage. Notez l'ordre : on **corrige**, *puis* on met un filet. L'inverse — masquer en aval et laisser la faute dans le code — revient à faire circuler la PII dans tout le réseau en espérant que le filtre ne tombe jamais.

> 💡 **Il existe un troisième endroit : le SDK de l'application.** On filtre alors avant même que la donnée ne sorte du processus — ce qu'exigent certaines politiques internes. Le dépôt en garde un exemple à lire, `PiiMaskingConfiguration.java`, qui remplace les emails des logs par `***@***`. Il ne fonctionne qu'avec le **Starter** du Lab 2, pas avec l'agent : les deux ne se branchent pas au SDK par le même endroit.

### Partie 3 — Le filet de sécurité : masquer au collecteur

5.  **Écrire la règle OTTL** dans `manifests/80-otel-security-values.yaml` : elle supprime `user.email` et `http.request.header.authorization` de **tous** les spans, et masque les emails dans **tous** les bodies de logs — quel que soit le service, corrigé ou non.

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

6.  **Appliquer, et rejouer la requête fautive.** Le code de `review-service` écrit toujours l'email et le token : c'est justement ce qu'on veut vérifier — que le collecteur les arrête quand même.

```bash
helm upgrade otel-demo open-telemetry/opentelemetry-demo \
  --version 0.40.9 -n otel-demo \
  -f manifests/values-training.yaml \
  -f manifests/30-otel-collector-values.yaml \
  -f manifests/60-otel-metrics-values.yaml \
  -f manifests/70-otel-traces-values.yaml \
  -f manifests/80-otel-security-values.yaml
kubectl rollout status daemonset/otel-collector-agent -n otel-demo

# rejouer un POST avec un email marqueur :
curl -X POST http://$PF_HOST:$APP_PORT/api/reviews \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.SECRET-JWT-TOKEN" \
  -d '{"productId": "OLJCESPC7Z", "rating": 5, "comment": "collector-mask", "userEmail": "collector-mask@example.com", "userName": "Safe User"}'
```

Dans Jaeger : la nouvelle trace `POST /api/reviews` n'a **plus** ni `user.email` ni le header `Authorization`. Dans OpenSearch : `collector-mask@example.com` est introuvable, le log montre `***@***`.

La trace est propre alors que le code est fautif : le filet a retenu. C'est ce que vous voulez le jour où la faute vient d'un service que vous ne pouvez pas corriger.

> ⚠️ **Mais lisez le log en entier.** Relevé sur le cluster de la formation, après masquage :
>
> ```text
> Creating review for product OLJCESPC7Z by Jean Dupont <***@***>
> ```
>
> L'email est masqué, **le nom ne l'est pas** — et c'est une donnée personnelle au même titre. Le collecteur ne sait masquer que ce qui a une **forme reconnaissable** : un email a un `@`, un IBAN un préfixe, une carte bancaire seize chiffres. « Jean Dupont » ressemble à n'importe quelle suite de mots, et le motif qui l'attraperait masquerait aussi « Creating review ».
>
> Voilà la vraie limite du filet, et la raison pour laquelle l'étape 4 reste la correction principale : le code, lui, **sait** que ce champ est un nom.
>
> **Sauf si le log est structuré.** Le vrai problème n'est pas le nom, c'est qu'il est **noyé dans une phrase**. Écrit comme un champ à part — `user.name` dans les attributs du log plutôt que dans le texte — il redevient adressable par sa clé, et le collecteur le supprime comme il supprime `user.email` des spans à l'étape 5 : `delete_key(log.attributes, "user.name")`, sans rien avoir à reconnaître. Une raison de plus de structurer ses logs.

7.  **Et dans un vrai projet, on fait les deux.** Le filet n'est pas une excuse : la PII a bel et bien quitté le processus, traversé le réseau, et n'a été arrêtée qu'au collecteur — un maillon qui peut être mal configuré, contourné par un service qui exporte ailleurs, ou remis à zéro par un `helm upgrade` malheureux. La correction de l'étape 4 reste donc la première chose à faire ; ce lab la laisse de côté uniquement pour que la démonstration ci-dessus soit visible.

C'est la **défense en profondeur** : le code ne produit pas la donnée, et le collecteur protège ce que le code ne couvre pas — les autres services, l'instrumentation automatique, et la faute qui reviendra un jour.

## Livrable

La preuve **avant / après** : capture de la trace avec le JWT et l'email (partie 1), et de la même requête une fois le collecteur configuré (partie 3), alors que le code fautif n'a pas bougé — plus la recherche OpenSearch vide sur `collector-mask@example.com`.
