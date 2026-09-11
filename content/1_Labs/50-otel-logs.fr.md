---
title: 'Lab 5 — Logs structurés et corrélés'
date: 2026-07-06T09:50:00+02:00
draft: false
weight: 50
tags: ["OpenTelemetry", "logs", "Logback", "OpenSearch"]
---

`review-service` écrit ses logs avec **SLF4J/Logback**, comme la plupart des applications Java. Dans ce lab, vous suivez le trajet complet d'un log : Logback → appender OpenTelemetry (injecté par l'agent) → OTLP → collecteur → **OpenSearch** — et surtout, vous exploitez la **corrélation log ↔ trace**.

Un mot sur ce que ce lab enseigne, pour éviter un malentendu : le sujet n'est pas le **transport**, c'est le **modèle de données** et la **corrélation**. Un log OpenTelemetry est un LogRecord structuré — corps, sévérité, ressource, `traceId` — et cette forme est la même qu'il arrive par OTLP ou qu'il soit relu depuis un fichier. Nous prenons OTLP parce que notre service est instrumenté ; l'étape bonus montre l'autre chemin, celui des applications qu'on ne peut pas toucher.

## Prérequis

* Labs 1 à 3 terminés.
* Les accès ouverts (`./scripts/open-ui.sh`).
* Les variables de la formation chargées dans votre shell : `. ./scripts/env.sh`. Elles donnent le port du review-service (`$APP_PORT`, accès **direct** au service, pas via le frontend-proxy) et `$PF_HOST`, le nom par lequel vous le joignez.

## Étapes

1.  **Les logs « à l'ancienne » :**

```bash
kubectl logs -n otel-demo deployment/review-service --tail=20
```

> `kubectl logs` lit la sortie console du conteneur : du texte brut, sans contexte, service par service. Impossible de croiser avec une trace.

2.  **Revenir à la version « agent Java » :**

Le Lab 2 s'est terminé avec le build **starter** déployé. Notez-le : lui aussi capture les logs, vous en verriez donc dans Grafana sans rien changer. On revient à l'agent parce que c'est **l'approche que suivent les labs suivants** — le Lab 6 active son pont Micrometer (`OTEL_INSTRUMENTATION_MICROMETER_ENABLED`), une option qui n'existe que chez lui.

Agent et starter sont deux alternatives : les laisser ensemble installerait deux SDK dans la même JVM. On redéploie donc l'image par défaut — celle qui ne contient pas le starter — puis on active l'agent :

```bash
./scripts/deploy.sh
kubectl set env -n otel-demo deployment/review-service \
  JAVA_TOOL_OPTIONS="-javaagent:/otel/opentelemetry-javaagent.jar"
kubectl rollout status -n otel-demo deployment/review-service
```

{{%expand "Comment l'agent capture-t-il les logs ?" %}}
L'agent détecte Logback et y **injecte l'équivalent de l'appender OpenTelemetry** (`io.opentelemetry.instrumentation:opentelemetry-logback-appender`). Chaque événement Logback devient un **LogRecord** OTel : timestamp, sévérité, body, attributs... et surtout le **`trace_id`/`span_id` courant** si le log est émis pendant une requête tracée.

Le **Spring Boot Starter** de la partie 2 du Lab 2 fait la même chose, autrement : l'appender est une dépendance compilée dans l'application, qu'il branche sur Logback au démarrage. D'où le constat du début de cette étape : les deux approches produisent des logs corrélés.
{{% /expand%}}

3.  **Générer des logs corrélés :**

```bash
. ./scripts/env.sh   # si ce n'est pas déjà fait dans ce terminal
curl http://$PF_HOST:$APP_PORT/api/reviews
curl -X POST http://$PF_HOST:$APP_PORT/api/reviews \
  -H "Content-Type: application/json" \
  -d '{"productId": "OLJCESPC7Z", "rating": 4, "comment": "Très bon rapport qualité/prix", "userEmail": "marie.curie@example.com", "userName": "Marie Curie"}'
```

4.  **Retrouver ces logs dans Grafana :**

*Explore* → datasource **OpenSearch** → requête Lucene :

```text
resource.service.name:"review-service"
```

Puis **cliquez sur l'onglet `Logs`**, juste sous le champ de requête, **avant** de lancer la requête.

> 💡 Les cinq onglets — *Metric*, **Logs**, *Raw Data*, *Raw Document*, *Traces* — sont alignés sous le champ *Lucene query*, et l'éditeur ouvre sur **Metric** : il compte les documents au lieu de les afficher. Cliquez sur **Logs**, puis lancez la requête avec le **bouton bleu en haut à droite** (icône ↻) : le panneau *Logs* apparaît, une ligne par message.

Dépliez le log `Creating review for product...`. Quels champs OTel voyez-vous autour du message ?

{{%expand "Réponse" %}}
Le LogRecord est **structuré** :
* `body` : le message ;
* `severity.text` / `severity.number` : le niveau (INFO...) ;
* `resource.service.name`, `k8s.pod.name`... : la **ressource** (qui a émis) ;
* `instrumentationScope.name` : le logger (`fr.k8sschool.reviews.ReviewController`) ;
* **`traceId` et `spanId`** : la corrélation avec la trace en cours.

Au passage : le message contient l'**email du client** en clair... Gardez ça en tête pour le Lab 8 (RGPD).
{{% /expand%}}

5.  **Rendre le `traceId` cliquable.** Dans le log déplié, le `traceId` s'affiche — mais **rien ne s'y attache** : c'est du texte inerte. Rien ne relie encore OpenSearch à Jaeger dans ce sens-là. À vous de le déclarer :

*Connections → Data sources → **OpenSearch** → section **Data links** → + Add* :
* **Field** : `traceId`
* **Internal link** : coché, datasource **Jaeger**
* **Query** : `${__value.raw}`

*Save & test*, puis retournez dans *Explore* et relancez la requête (sans oublier l'onglet **Logs**). Dépliez un log : une section **Links** est apparue en tête, avec `traceId` et un bouton **Jaeger**.

> 🔑 **Le champ `Query` est celui qu'on oublie, et sans lui le lien ne sert à rien.** Il est vide par défaut : le bouton apparaît quand même, ouvre bien Jaeger… mais sans rien lui demander, donc sur une trace vide. `${__value.raw}` est la **valeur brute du champ** de la ligne courante — ici le `traceId` du log que vous avez déplié. C'est elle qui part comme requête vers Jaeger.
>
> Notez que pour un lien **interne**, ce champ ne contient pas une URL malgré son intitulé dans certaines versions de Grafana : c'est la **requête** adressée à la datasource cible. Une URL n'a de sens que pour un lien externe, quand on décoche *Internal link*.

{{%expand "Solution" %}}
Le fichier [`50-otel-logs-datasource.json`](../50-otel-logs-datasource.json) contient la datasource complète, `dataLinks` inclus. On la remplace par l'API :

```bash
. ./scripts/env.sh   # si ce n'est pas déjà fait dans ce terminal

curl -sS -X PUT http://$PF_HOST:$UI_PORT/grafana/api/datasources/uid/webstore-logs \
  -H "Content-Type: application/json" \
  -d @content/1_Labs/50-otel-logs-datasource.json
```

C'est un **PUT** : il remplace la datasource entière, pas seulement le champ ajouté. D'où la présence de tout le reste (`timeField`, `logMessageField`…) dans le fichier — l'omettre l'effacerait. Et cela ne fonctionne que parce que la démo provisionne cette datasource avec `editable: true` (`readOnly: false` dans la réponse de l'API) : une datasource verrouillée refuserait la modification.

Le cœur du fichier tient en cinq lignes :

```json
"dataLinks": [
  {
    "field": "traceId",
    "url": "${__value.raw}",
    "datasourceUid": "webstore-traces"
  }
]
```

Les trois clés correspondent aux trois réglages de l'interface : `field` le champ à rendre cliquable, `datasourceUid` la cible (`webstore-traces`, l'UID de Jaeger relevé au Lab 4 — comme pour les panels, c'est l'UID qui désigne une datasource, jamais son nom d'affichage), et `url` la requête. Oui, `url` : la clé porte ce nom pour des raisons historiques, mais dès qu'un `datasourceUid` est présent, Grafana en lit le contenu comme une **requête**, pas comme une adresse.

Le bouton porte le nom de la datasource cible — d'où le sobre **Jaeger**. Pour l'intituler autrement, remplissez le champ **Label** de l'interface, qui se sérialise en `"title"` : `"title": "Voir la trace"` et le bouton s'appelle ainsi. C'est purement cosmétique, et sans effet sur le fonctionnement du lien.
{{% /expand%}}

> 💡 **Pourquoi ce lien n'existait-il pas déjà ?** Parce que la démo configure la corrélation **dans l'autre sens** : la datasource Jaeger contient un bloc `tracesToLogsV2` qui, depuis une trace, va chercher les logs correspondants (`traceId:"…" AND spanId:"…"`). Le chemin retour — du log vers la trace — est un réglage **distinct**, porté par le `dataLinks` de la datasource de logs. Les deux sens sont indépendants : en configurer un ne donne pas l'autre.

> ⚠️ **Ce lien ne survivra pas à un redémarrage de Grafana.** La datasource OpenSearch est **provisionnée** par une ConfigMap (`grafana-datasources`, posée par Helm) : un sidecar la relit à chaque démarrage et **réécrit la datasource par-dessus**. Tout ce que vous avez ajouté à l'exécution — par l'interface comme par l'API — disparaît alors, sans le moindre message. Constaté en préparant ce lab : Grafana redémarre, et le bloc `dataLinks` n'est plus là.
>
> Le `editable: true` dit seulement que Grafana **accepte** votre modification : sans lui, le formulaire serait grisé et l'API refuserait le PUT. Il ne dit rien de ce qui se passe au redémarrage, où le fichier de provisioning reprend la main et écrase tout.
>
> Si le cas se présente, refaites la manip — c'est l'affaire de dix secondes. Mais retenez la leçon : en production, ce lien ne se règle pas à la souris, il s'écrit dans le fichier de provisioning et se versionne dans Git. Exactement le même raisonnement que pour le dashboard du Lab 4, que vous avez exporté en JSON pour le committer plutôt que de le laisser vivre dans Grafana.

6.  **Du log à la trace en un clic :**

Toujours dans le log déplié, cliquez le bouton **Jaeger** de la section *Links*. Grafana **scinde l'écran** : vos logs restent à gauche, la trace s'affiche à droite — `POST /api/reviews` avec ses spans HTTP, catalogue et SQL. Vous avez sous les yeux la trace exacte qui a produit ce log, sans perdre le log de vue. C'est tout l'intérêt de la corrélation : les deux signaux côte à côte, et non l'un après l'autre.

> 💡 **Vous n'avez pas quitté Grafana.** Le bouton s'appelle *Jaeger*, mais l'interface de Jaeger ne s'ouvre nulle part : c'est **Grafana qui dessine la trace**, avec les données qu'il vient de demander à Jaeger par la datasource `webstore-traces`. Jaeger n'est plus qu'un magasin de traces derrière Grafana — comme Prometheus pour les métriques et OpenSearch pour les logs. C'est la suite directe du Lab 4 : un seul outil devant les yeux, trois back-ends derrière.

7.  **Comprendre le trajet côté collecteur :**

```bash
kubectl get configmap otel-collector-agent -n otel-demo -o yaml | grep -A12 "logs:"
```

{{%expand "Réponse" %}}
Le pipeline `logs` de la démo :

```yaml
logs:
  receivers: [otlp]
  processors: [k8sattributes, memory_limiter, resourcedetection, resource, batch]
  exporters: [opensearch, debug]
```

Les LogRecords arrivent en **OTLP** (poussés par l'agent), sont enrichis, puis indexés dans **OpenSearch** (index `otel-logs-*`) — celui que requête la datasource Grafana.

> `k8sattributes` en tête n'a rien de spécifique aux logs : c'est le même preset
> `kubernetesAttributes` du chart, vu au Lab 3 sur le pipeline `traces` — il attache
> `k8s.pod.name`, `k8s.namespace.name`… avant que quoi que ce soit d'autre ne s'exécute,
> puisqu'il a besoin du contexte de connexion.
{{% /expand%}}

## Pour aller plus loin — l'autre chemin, lire les fichiers

Tout ce lab repose sur un choix : l'application **pousse** ses logs au collecteur en OTLP. Il existe un second chemin, et il vaut la peine d'être connu — ne serait-ce que pour savoir quand ne pas le prendre.

Le collecteur sait aussi **lire des fichiers**. C'est le receiver `filelog`, qui parcourt `/var/log/pods/*/*/*.log` — là où le kubelet écrit tout ce que les conteneurs envoient sur leur sortie standard. Il répond à un cas que ce lab n'a pas traité : les applications qu'on ne peut **pas** instrumenter, applis legacy, pods tiers, outils dont on n'a pas les sources.

Il ne s'active pas comme les receivers du Lab 3. Lire `/var/log/pods` suppose de monter un répertoire du nœud dans le pod, ce qui ne se configure pas dans `config:` mais dans la forme même du DaemonSet. D'où un **preset**, qui pose le tout d'un bloc — receiver, branchement au pipeline `logs`, volumes, et l'opérateur qui décode le format du runtime :

```yaml
# dans un fichier de values passé à `helm upgrade`, comme au Lab 3
opentelemetry-collector:
  presets:
    logsCollection:
      enabled: true
```

> 💡 **Ces blocs sont des *values* Helm, pas la configuration du collecteur.** Le collecteur est un **sous-chart** de `opentelemetry-demo` : tout ce qui le concerne se range sous la clé `opentelemetry-collector:`, comme depuis le Lab 3. Ce qui se trouve dessous en `config:` finit bien dans la configuration du collecteur, mais ce qui se trouve dessous en `presets:` non — c'est Helm qui le lit, pour fabriquer receiver, volumes et pipeline d'un seul geste.

### Le conflit avec ce que vous venez de faire

⚠️ **Activer les deux chemins pour les mêmes pods coûte cher et n'apporte rien.** `filelog` lit les fichiers de **tous** les conteneurs du nœud — mesuré sur le cluster de la formation : 47 conteneurs, 228 Mo de fichiers. Or les 28 pods de la démo poussent déjà leurs logs en OTLP.

Chaque ligne arriverait donc **deux fois** dans OpenSearch : une fois en LogRecord structuré avec son `traceId`, une fois en texte brut sans corrélation. Stockage et ingestion doublés, sans une information de plus — et le collecteur, déjà juste en mémoire (voir le `memory_limiter` du Lab 3), encaisserait le double.

Quand les deux doivent coexister — `filelog` pour le parc non instrumenté, OTLP pour les services qui le sont — on écarte les seconds avec un `exclude`. Les chemins ont la forme `/var/log/pods/<namespace>_<pod>_<uid>/<conteneur>/*.log` :

```yaml
opentelemetry-collector:
  config:
    receivers:
      filelog:
        exclude:
          # celle du preset, à ne pas perdre : les logs du collecteur lui-même
          - /var/log/pods/otel-demo_otel-collector*_*/opentelemetry-collector/*.log
          # la vôtre : le service qui pousse déjà ses logs en OTLP
          - /var/log/pods/otel-demo_review-service-*_*/review-service/*.log
```

> ⚠️ **Pourquoi deux lignes, alors qu'on ne veut en écarter qu'une ?** Parce que Helm fusionne votre `config:` par-dessus celle du preset, et que pour une **liste** YAML, fusionner veut dire **remplacer** : votre `exclude` ne s'ajoute pas à celui du preset, il prend sa place. Or le preset en avait déjà posé un, celui qui écarte **les logs du collecteur lui-même**. Le réécrire sans le reprendre, c'est laisser le collecteur lire ses propres logs — qui lui font écrire d'autres logs, qu'il relit à leur tour.

### Alors, OTLP ou `filelog` ?

> 💡 **Les deux chemins en une phrase.** Avec **OTLP**, c'est l'**application qui pousse** ses logs au collecteur, déjà structurés et porteurs de leur `traceId` — c'est ce que fait le `review-service` depuis le début de ce lab. Avec **`filelog`**, c'est le **collecteur qui va lire** les fichiers que Kubernetes écrit sous `/var/log/pods/`, c'est-à-dire la sortie standard des conteneurs : du texte, tel qu'il a été imprimé, sans rien demander à l'application.

Aucun des deux n'est « le bon » dans l'absolu — c'est l'application qui tranche.

* **Application instrumentée → OTLP.** Le SDK produit des LogRecords déjà structurés : sévérité normalisée, attributs typés, ressource, `traceId`. Rien à parser, rien à deviner. C'est le cas du `review-service`, donc de ce lab.
* **Application qu'on ne peut pas toucher → `filelog`.** Universel, tous langages, aucun code à modifier — et le fichier **survit au collecteur** : s'il sature ou redémarre, la lecture reprend au point d'arrêt (option `storeCheckpoints`). L'appender OTLP, lui, garde ses LogRecords **en mémoire** : collecteur indisponible, logs perdus. C'est exactement ce que racontent les `data refused due to high memory usage` du Lab 3.

En pratique, un parc Kubernetes réel mélange les deux, parce qu'il mélange les deux sortes d'applications. Ce qu'il ne faut pas, c'est les faire se recouvrir.

### La corrélation ne vient pas du transport

C'est le point à emporter. Regardez la sortie console de votre service :

```text
2026-08-21T07:53:09.459Z  INFO 1 --- [review-service] [nio-8080-exec-4] fr.k8sschool.reviews.ReviewController : Creating review for product…
```

Aucun `traceId` nulle part. Relus par `filelog`, ces logs arriveraient dans OpenSearch **sans lien vers la trace**, et l'étape 5 de ce lab n'aurait plus d'objet — non pas à cause du transport, mais parce que l'identifiant n'est **pas dans le texte**.

Il y est pourtant, ailleurs : dans le **MDC**. *Mapped Diagnostic Context*, une petite table clé/valeur que SLF4J attache au **thread courant**, et dont Logback sait insérer les valeurs via `%X{clé}`. L'agent OpenTelemetry y dépose automatiquement `trace_id` et `span_id` chaque fois qu'une ligne est écrite pendant une requête tracée. Ils sont donc **déjà là** — c'est le pattern par défaut de Spring Boot qui ne les affiche pas. Les faire apparaître tient en une ligne :

```properties
# apps/review-service/src/main/resources/application.properties
logging.pattern.level=%5p [%X{trace_id:-},%X{span_id:-}]
```

D'où la différence entre les deux transports. `filelog` ne voit **que la ligne imprimée dans le fichier** : si le `trace_id` n'y figure pas, il n'arrivera jamais dans OpenSearch — d'où la ligne de configuration ci-dessus. L'appender OTLP ne passe pas par le fichier du tout : il va chercher le `trace_id` dans le MDC au moment où la ligne est écrite, et l'attache au LogRecord. Rien à configurer.

Dans les deux cas le `trace_id` **existe déjà** : c'est l'instrumentation qui l'a créé, jamais le transport. Le transport décide seulement du travail qu'il vous reste à faire pour qu'il arrive à bon port.

## Livrable

Une capture « log → trace » : le log `Creating review...` déplié dans Grafana avec son `traceId`, et la trace Jaeger correspondante ouverte.
