---
title: 'Lab 7 bonus — Voir le bagage, et s''en servir'
date: 2026-08-27T10:00:00+02:00
draft: false
weight: 71
tags: ["OpenTelemetry", "traces", "baggage", "sampling", "multi-tenant"]
---

Le Lab 7 vous fait lire trois lignes de `Baggage` dans `ReviewController.java`, puis vous annonce que le bagage « voyage avec le contexte » — et vous ne voyez **rien**. Ni dans Jaeger, ni ailleurs. Cette page comble ce trou : on rend le bagage visible, on regarde jusqu'où il descend, et on s'en sert pour garder 100 % des traces d'un client donné.

Contrairement aux autres bonus, celle-ci se manipule : une variable d'environnement, quelques `curl`, un `helm upgrade`.

## 1. Pourquoi on ne voit rien

Un **attribut** est une donnée du span : le SDK l'exporte avec lui, Jaeger l'affiche.

Un **bagage** n'est *pas* une donnée du span. C'est une valise que le contexte trimballe : le SDK la sérialise dans un en-tête HTTP au moment d'appeler le service suivant, et c'est tout. Elle ne part jamais vers le collecteur, donc rien n'en arrive jamais dans Jaeger.

```text
attribut :  code → span → collecteur → Jaeger        (visible)
bagage   :  code → contexte → en-tête HTTP → service suivant   (invisible)
```

D'où le silence du Lab 7. Le mécanisme fonctionne pourtant, et pour le prouver il faut faire passer le bagage du premier rail au second — c'est exactement ce que fait la section suivante.

**« Mais le bagage n'est vraiment pas envoyé au collecteur ? »** Non : **OTLP ne transporte pas le bagage**. Le protocole décrit un span par son nom, ses attributs, ses événements, son statut — il n'a aucun champ pour ça.

Et une copie automatique serait coûteuse. Recopier toutes les clés du bagage sur **chaque** span d'une trace multiplie la donnée stockée ; et un bagage peut contenir ce qu'un service amont y a mis, y compris ce que vous ne tenez pas à garder six mois dans Jaeger.

D'où la règle : **ce que vous voulez voir dans les traces, vous l'y mettez explicitement**, clé par clé. C'est exactement ce que demande la variable de la section suivante — elle ne copie que les clés que vous nommez.

**Constatez-le tout de suite**, avant d'avoir rien changé. Envoyez une requête portant un bagage bien visible :

```bash
. ./scripts/env.sh   # si ce n'est pas déjà fait dans ce terminal
curl -X POST http://$PF_HOST:$APP_PORT/api/reviews \
  -H "Content-Type: application/json" \
  -H "traceparent: 00-babbaba9e00000000000000000000009-00f067aa0ba902b7-01" \
  -H "baggage: app.tenant=acme,app.review.channel=mobile" \
  -d '{"productId": "DOESNOTEXIST", "rating": 5, "comment": "sans copie", "userEmail": "a@b.c", "userName": "A"}'
```

Le produit `DOESNOTEXIST` n'existe pas, et c'est voulu : la requête échoue, or `keep-errors` (Lab 7) conserve **100 %** des traces en erreur. La vôtre sera donc bien là, sans dépendre du tirage à 25 %.

Cherchez `babbaba9e00000000000000000000009` dans le champ **Trace ID** de Jaeger, ouvrez le span `POST /api/reviews` et dépliez ses *Tags*. Relevé sur le cluster de la formation :

```text
21 attributs sur le span serveur
   app.tenant         : absent
   app.review.channel : absent
```

Vingt et un attributs, et pas un seul ne vient des deux clés pourtant envoyées dans l'en-tête `baggage`. Ce qui n'a pas été copié en attribut **dans le processus émetteur** n'existe nulle part en aval.

Conséquence pratique, et elle surprend : **aucun processor du collecteur ne peut récupérer un bagage**, puisqu'il ne lui arrive jamais. La conversion bagage → attribut se fait toujours du côté de l'application — par la variable d'environnement de la section suivante, ou par un `BaggageSpanProcessor` ajouté au SDK.

**Au fait, qu'est-ce qu'on peut mettre dans un bagage ?** Des paires **chaîne → chaîne**, et rien d'autre : ni nombre, ni booléen, ni objet, ni liste. Le format est décrit par la [spécification W3C Baggage](https://www.w3.org/TR/baggage/), sœur de `traceparent`, et se résume à un en-tête :

```text
baggage: app.tenant=acme,app.review.channel=mobile
```

Deux limites du standard valent d'être retenues, elles reviendront à la section 5 : l'en-tête est plafonné à **8 192 octets** et **64 entrées**, et il circule **en clair**.

## 2. Rendre le bagage visible

L'agent Java sait recopier des clés du bagage dans les attributs de **chaque span qu'il crée**. La fonctionnalité est marquée expérimentale, elle s'active par une variable d'environnement — et il faut **nommer les clés** attendues, il n'y a pas de copie aveugle :

```bash
kubectl set env -n otel-demo deployment/review-service \
  OTEL_JAVA_EXPERIMENTAL_SPAN_ATTRIBUTES_COPY_FROM_BAGGAGE_INCLUDE="app.review.channel,app.tenant"
kubectl rollout status deployment/review-service -n otel-demo
```

C'est le pont entre les deux rails du schéma ci-dessus : à partir de maintenant, ce qui est dans le bagage se retrouve **aussi** sur les spans.

> ⚠️ **Laissez passer quelques secondes avant le premier `curl`.** Changer une variable d'environnement remplace le pod, et le `kubectl port-forward` qui vous donne accès au `review-service` était accroché à l'**ancien** : il meurt avec lui. Si `curl` répond `Failed to connect`, c'est cela — le superviseur de `./scripts/open-ui.sh` rétablit l'accès tout seul, attendez quelques secondes et recommencez.

## 3. L'expérience

Une seule requête, avec deux en-têtes fabriqués à la main — un `traceparent` pour retrouver la trace tout de suite, un `baggage` qui joue le rôle du service appelant :

```bash
. ./scripts/env.sh   # si ce n'est pas déjà fait dans ce terminal
curl -X POST http://$PF_HOST:$APP_PORT/api/reviews \
  -H "Content-Type: application/json" \
  -H "traceparent: 00-babbaba9e00000000000000000000001-00f067aa0ba902b7-01" \
  -H "baggage: app.tenant=acme,app.review.channel=mobile" \
  -d '{"productId": "OLJCESPC7Z", "rating": 5, "comment": "bagage", "userEmail": "a@b.c", "userName": "A"}'
```

> ⚠️ **Jaeger ne trouve pas la trace ? C'est normal une fois sur quatre.** Contrairement à celle de la section 1, cette requête réussit et va vite : elle n'est retenue ni par `keep-errors` ni par `keep-slow`, et tombe donc dans `sample-the-rest` — 25 %. Relancez la commande en changeant le **dernier caractère** du `traceparent` (`…002`, puis `…003`…) jusqu'à ce que Jaeger trouve la trace, et cherchez le nouvel identifiant. Relevé sur le cluster de la formation : huit requêtes envoyées, deux traces conservées.
>
> Prenez-en une qui compte **une quinzaine de spans** : une trace de neuf spans a été tranchée avant que les derniers n'arrivent (`decision_wait: 5s`), et il lui manque justement la fin, là où le bagage est le plus parlant.
>
> **Renvoyer la requête avec le même `traceparent` ne sert à rien** — c'est la première idée qui vient, et elle ne marche pas. Le tail sampling décide **une fois par `traceId`**, pas par requête : ce qui arrive ensuite sous le même identifiant est un « span tardif » qui suit la décision déjà prise. Mesuré sur le cluster de la formation : douze identifiants rejoués quatre à cinq fois chacun, aucune trace n'a changé de sort. Et Jaeger regrouperait de toute façon toutes ces requêtes en une seule trace, chaque span en plusieurs exemplaires.

Ouvrez la trace dans Jaeger et dépliez les spans. Relevé sur le cluster de la formation, en ne gardant que les attributs `app.*` :

```text
review-service   POST /api/reviews          app.review.channel=mobile  app.tenant=acme
review-service   product-catalog.lookup     app.review.channel=web     app.tenant=acme
review-service   GET                        app.review.channel=web     app.tenant=acme
frontend         GET /api/products/{productId}      (aucun)
product-catalog  ProductCatalogService/GetProduct   (aucun)
review-service   ReviewRepository.save      app.review.channel=web     app.tenant=acme
review-service   Session.persist …          app.review.channel=web     app.tenant=acme
review-service   INSERT otel                app.review.channel=web     app.tenant=acme
review-service   Transaction.commit         app.review.channel=web     app.tenant=acme
```

Trois choses s'y lisent, et aucune n'était visible au Lab 7.

**`app.tenant=acme` descend jusqu'au span JDBC.** Personne n'a écrit cette valeur dans le code : elle est entrée par un en-tête HTTP, et elle ressort quatre couches plus bas, sur un span créé par le module JDBC de l'agent — du code qui n'a jamais entendu parler de « tenant ». C'est **toute** la différence avec un attribut : `Span.current().setAttribute(...)` ne marque que le span courant, le bagage marque tout ce qui suit dans le contexte.

**`mobile`, puis `web`.** Le span serveur porte la valeur envoyée par le client ; tous les suivants portent `web`. Entre les deux, il s'est passé ceci, à la ligne 114 de `ReviewController.java` :

```java
Baggage baggage = Baggage.current().toBuilder()   // reprend ce qui est arrivé (app.tenant=acme)
        .put("app.review.channel", "web")          // et écrase cette clé-là
        .build();
try (Scope ignored = baggage.makeCurrent()) { ... }  // à partir d'ici, et jusqu'à la fermeture
```

Vous voyez donc **une ligne de code agir**, et vous voyez sa portée : le `try` délimite exactement les spans qui portent `web`. `app.tenant`, que le code ne connaît pas, traverse sans être touché.

**Le `frontend` ne montre rien.** L'en-tête `baggage` lui est pourtant bien envoyé — le propagateur par défaut de l'agent est `tracecontext,baggage`, les deux partent ensemble. Mais le `frontend` est en Node.js, et personne n'y a activé de copie vers les attributs : il reçoit le bagage, le repropage à `product-catalog`, et n'en dit rien. **La copie en attributs est une décision par service**, pas une propriété de la trace.

> 💡 Sans la variable de la section 2, cette même requête donne exactement la trace du Lab 7 : aucun `app.tenant`, aucun `app.review.channel`, nulle part. Le bagage voyageait déjà — c'est le regard qui manquait.

## 4. À quoi ça sert : garder les traces d'un client

Le cas d'usage type du bagage, c'est le **tenant**. Une requête traverse cinq services ; seul le premier sait de quel client elle vient. Quand `product-catalog`, quatre sauts plus loin, met trois secondes sur une requête SQL, il n'a aucun moyen de savoir qui il faisait patienter : l'information est restée à l'entrée. Le bagage la lui apporte.

Et une fois `app.tenant` posé sur tous les spans, le collecteur peut **décider** dessus. Reprenez la politique du Lab 7 et ajoutez-lui une quatrième règle — « ce client-là, on garde tout » :

> 💡 **Le tail sampling, lui, n'a besoin de rien de tout ça.** Les trois politiques du Lab 7 décident sur ce que les spans portent déjà : un statut `ERROR`, une durée, un tirage au sort. C'est la règle générale du collecteur — **il ne peut trancher que sur ce qui est dans les spans**. Le bagage n'y étant pas, la seule façon de décider dessus est de l'y avoir copié en amont, dans l'application. Retirez la variable de la section 2 et cette quatrième politique cesse silencieusement de retenir quoi que ce soit : les requêtes du client `acme` retombent dans les 25 % du tirage ordinaire, sans le moindre message d'erreur nulle part.

```yaml
policies:
  - name: keep-tenant-acme
    type: string_attribute
    string_attribute:
      key: app.tenant
      values: [acme]
  # … puis les trois politiques du Lab 7, inchangées
```

> ⚠️ **Ce fichier ne s'empile pas sur celui du Lab 7, il le remplace.** Helm fusionne les *maps*, mais remplace une *liste* en bloc : un fichier ne contenant que `keep-tenant-acme` effacerait les trois autres politiques. D'où le fichier de référence [`71-otel-traces-values.yaml`](../71-otel-traces-values.yaml), qui les redonne toutes les quatre.

```bash
cp content/1_Labs/71-otel-traces-values.yaml manifests/

helm upgrade otel-demo open-telemetry/opentelemetry-demo \
  --version 0.40.9 -n otel-demo \
  -f manifests/values-training.yaml \
  -f manifests/30-otel-collector-values.yaml \
  -f manifests/60-otel-metrics-values.yaml \
  -f manifests/71-otel-traces-values.yaml
kubectl rollout status daemonset/otel-collector-agent -n otel-demo
```

Vingt requêtes ordinaires par client — ni en erreur, ni lentes, donc soumises aux 25 % de `sample-the-rest` :

```bash
for i in $(seq 1 20); do curl -s -o /dev/null -H "baggage: app.tenant=acme"   http://$PF_HOST:$APP_PORT/api/reviews; done
for i in $(seq 1 20); do curl -s -o /dev/null -H "baggage: app.tenant=globex" http://$PF_HOST:$APP_PORT/api/reviews; done
```

Dans Jaeger, cherchez l'opération `GET /api/reviews` avec le tag `app.tenant=acme`, puis `app.tenant=globex`. Relevé sur le cluster de la formation :

```text
app.tenant=acme    : 20 traces   ← les 20, sans exception
app.tenant=globex  :  4 traces   ← ~25 %, le tirage ordinaire
```

Le compteur du processor dit la même chose, sans compter de lignes à l'écran :

```promql
sum by (policy, sampled) (otelcol_processor_tail_sampling_count_traces_sampled_total{policy="keep-tenant-acme"})
```

```text
sampled="true"    20     ← exactement les 20 requêtes acme
sampled="false"  271       toutes les autres traces du cluster
```

> 💡 **Un seul service copie le bagage — et cela suffit.** L'attribut `app.tenant` n'existe que sur les spans du `review-service` : c'est le seul où la variable de la section 2 est posée. Or le tail sampling raisonne **trace par trace**, jamais span par span : `string_attribute` interroge tous les spans de la trace, la retient dès qu'**un seul** correspond, et conserve alors la trace **entière**. Cinq `POST` ordinaires envoyés avec `app.tenant=acme` sur le cluster de la formation le montrent — le tirage à 25 % n'en aurait gardé qu'un :
>
> ```text
> 5 traces sur 5 conservées, de 13 à 14 spans chacune
>   review-service  : 7 ou 8 spans, tous porteurs de app.tenant
>   frontend        : 4 spans, aucun attribut
>   product-catalog : 2 spans, aucun attribut
> ```
>
> Placez donc la copie sur le service **d'entrée**, celui qui voit passer toutes les requêtes. Ce qui ne marchera pas pour autant : chercher dans Jaeger « les spans lents de `product-catalog` pour le client acme », ou ventiler une métrique par client en aval. Ces deux-là exigent l'attribut sur les spans **de ce service-là** — donc la variable activée aussi sur lui.

C'est la boucle complète du chapitre : une valeur métier connue **du seul service d'entrée** voyage par le bagage, se dépose en attribut sur les spans, et devient ainsi un critère de décision pour le collecteur. Sans elle, la seule façon de garder les traces d'un client serait de monter l'échantillonnage pour tout le monde.

Les autres usages sont de la même famille : `app.rollout=canary` pour comparer les latences de deux versions, `app.device=mobile`, un identifiant de ticket support le temps d'un incident.

## 5. Le revers : c'est un en-tête, et il va loin

Deux propriétés du bagage à ne pas oublier, et elles annoncent le [Lab 8]({{% relref "80-otel-security.fr.md" %}}).

**Le client écrit ce qu'il veut.** Vous venez de le faire : `app.tenant=acme` a été fabriqué à la main dans un `curl`. Rien ne le distingue d'un bagage légitime — c'est le même problème que le `traceparent` de l'étape 4 du Lab 7. Un bagage qui arrive de l'extérieur est une **déclaration du client**, pas un fait ; sur un endpoint public, on le filtre à l'entrée et on repose soi-même les clés de confiance.

**Il voyage vers tout l'aval, sans exception.** Chaque service instrumenté le repropage au suivant, y compris vers des API tierces si votre code en appelle. N'y mettez donc **jamais** de donnée personnelle ni de secret : ce serait publier un e-mail ou un jeton dans un en-tête HTTP, chez des gens qui ne l'ont pas demandé — la faute que le Lab 8 corrige sur les attributs, en pire, puisqu'elle sort de votre système. Restez sur des étiquettes courtes et anodines, ce qui tombe bien : 8 Ko et 64 entrées, pas davantage.

## 6. Revenir à l'état du Lab 7

```bash
kubectl set env -n otel-demo deployment/review-service \
  OTEL_JAVA_EXPERIMENTAL_SPAN_ATTRIBUTES_COPY_FROM_BAGGAGE_INCLUDE-

helm upgrade otel-demo open-telemetry/opentelemetry-demo \
  --version 0.40.9 -n otel-demo \
  -f manifests/values-training.yaml \
  -f manifests/30-otel-collector-values.yaml \
  -f manifests/60-otel-metrics-values.yaml \
  -f manifests/70-otel-traces-values.yaml
```

Le `-` final du nom de variable la **supprime** — c'est la syntaxe de `kubectl set env`, la même qui retire `JAVA_TOOL_OPTIONS` au Lab 2.
