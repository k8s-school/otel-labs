---
title: 'Lab 5 — Logs structurées et corrélées'
date: 2026-07-06T09:50:00+02:00
draft: false
weight: 50
tags: ["OpenTelemetry", "logs", "Logback", "OpenSearch"]
---

`review-service` écrit ses logs avec **SLF4J/Logback**, comme la plupart des applications Java. Dans ce lab, vous suivez le trajet complet d'un log : Logback → appender OpenTelemetry (injecté par l'agent) → OTLP → collecteur → **OpenSearch** — et surtout, vous exploitez la **corrélation log ↔ trace**.

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

Le **Spring Boot Starter** de la partie 2 du Lab 2 fait la même chose, autrement : l'appender est une dépendance compilée dans l'application, qu'il branche sur Logback au démarrage. D'où le constat de l'étape 2 — les deux approches produisent des logs corrélés, et le Lab 4 les affiche indifféremment.

Et sans ni l'un ni l'autre ? On déclare l'appender à la main dans `logback.xml` et on construit le SDK (`LoggerProvider`) — c'est l'approche « SDK » vue en cours.
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

Puis **cliquez sur l'onglet `Logs`**, juste sous le champ de requête, **avant** de lancer *Run query*.

> ⚠️ **Sans ce clic, vous n'obtiendrez aucun log — et aucun message d'erreur.** L'éditeur de la datasource OpenSearch ouvre sur l'onglet **Metric**, réglé sur `Count` + *Date Histogram* : Grafana se contente de **compter** les documents et d'en dessiner un graphe à barres. Pas une seule ligne de log n'est affichée, donc rien à déplier, et le message reste invisible — ce qui laisse croire que la requête est fausse. Elle ne l'est pas.
>
> Les cinq onglets — *Metric*, **Logs**, *Raw Data*, *Raw Document*, *Traces* — sont alignés sous le champ *Lucene query*. Cliquez sur **Logs**, puis *Run query* : le panneau *Logs* apparaît, une ligne par message. C'est exactement ce que fait, en JSON, le panel « Logs » du dashboard de référence du Lab 4 : `"metrics": [{"type": "logs"}]`.

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

{{%expand "Solution — en une commande" %}}
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
> Le `editable: true` de la configuration **autorise** la modification ; il ne la rend pas **durable**. Deux notions distinctes, et une confusion fréquente.
>
> Si le cas se présente, refaites la manip — c'est l'affaire de dix secondes. Mais retenez la leçon : en production, ce lien ne se règle pas à la souris, il s'écrit dans le fichier de provisioning et se versionne dans Git. Exactement le même raisonnement que pour la règle d'alerte du Lab 4, qu'on écrirait côté Prometheus plutôt que dans Grafana.

6.  **Du log à la trace en un clic :**

Toujours dans le log déplié, cliquez le bouton **Jaeger** de la section *Links*. Grafana **scinde l'écran** : vos logs restent à gauche, Jaeger s'ouvre à droite, garni de la trace que la requête `${__value.raw}` vient de réclamer. Vous avez sous les yeux la trace exacte qui a produit ce log — `POST /api/reviews` avec ses spans HTTP, catalogue et SQL — sans perdre le log de vue. C'est tout l'intérêt de la corrélation : les deux signaux côte à côte, et non l'un après l'autre.

7.  **Comprendre le trajet côté collecteur :**

```bash
kubectl get configmap otel-collector-agent -n otel-demo -o yaml | grep -A8 "logs:"
```

{{%expand "Réponse" %}}
Le pipeline `logs` de la démo :

```yaml
logs:
  receivers: [otlp]
  processors: [memory_limiter, resourcedetection, resource, batch]
  exporters: [opensearch, debug]
```

Les LogRecords arrivent en **OTLP** (poussés par l'agent), sont enrichis, puis indexés dans **OpenSearch** (index `otel-logs-*`) — celui que requête la datasource Grafana.
{{% /expand%}}

8.  **Bonus — receiver `filelog` :** le collecteur sait aussi **lire des fichiers de logs** (applis legacy, pods non instrumentés). Sur le modèle du Lab 3, ajoutez à la config du collecteur un receiver `filelog` pointé sur `/var/log/pods/*/*/*.log` et branchez-le au pipeline `logs` (le chart monte déjà les volumes en mode DaemonSet via le preset `logsCollection`). À discuter avec le formateur selon le temps restant.

## Livrable

Une capture « log → trace » : le log `Creating review...` déplié dans Grafana avec son `traceId`, et la trace Jaeger correspondante ouverte.
