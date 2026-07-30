---
title: 'Lab 1 — Démarrage de la stack d''observabilité'
date: 2026-07-06T09:00:00+02:00
draft: false
weight: 10
tags: ["OpenTelemetry", "Grafana", "Jaeger", "Kind"]
---

Bienvenue dans l'équipe SRE de l'**Astronomy Shop** 🔭 — une boutique e-commerce composée d'une vingtaine de micro-services, instrumentée avec OpenTelemetry ([démo officielle](https://opentelemetry.io/docs/demo/)).

Dans ce premier lab, entièrement guidé, vous démarrez la plateforme d'observabilité complète : le **collecteur OpenTelemetry**, **Grafana**, **Jaeger** (traces), **Prometheus** (métriques) et **OpenSearch** (logs), ainsi que la boutique elle-même et son générateur de trafic.

> 💡 Toute la stack tourne dans un cluster Kubernetes local (**Kind**). Kubernetes n'est pas le sujet de cette formation : toutes les commandes `kubectl` sont fournies, avec leur explication.

## Prérequis

* Docker installé et fonctionnel (`docker ps` ne renvoie pas d'erreur).
* `kubectl`, `helm` et `ktbx` installés.
* `kind` **≥ v0.27** (`kind version`) — les versions plus anciennes ne savent pas charger d'images dans les nœuds récents (erreur `failed to detect containerd snapshotter`). Mise à jour : `go install sigs.k8s.io/kind@v0.30.0`.
* Le dépôt de la formation cloné :

```bash
git clone https://github.com/k8s-school/otel-labs.git
cd otel-labs
```

## Étapes

1.  **Créer le cluster et installer la démo OpenTelemetry :**

```bash
./scripts/up.sh -c
```

> 🏫 **Serveur partagé** : si le formateur vous a fourni un compte `student<N>` sur un serveur commun, la commande est **la même** — le cluster et la stack, c'est vous qui les créez, sur votre compte. Ce qui a été préparé pour vous, c'est le compte, le dépôt déjà cloné et votre environnement de travail.
>
> Vous partagez la machine avec les autres participants : pour que vos `port-forward` n'entrent pas en conflit avec les leurs, chacun écoute sur **sa propre adresse de boucle locale** au lieu de `localhost` — `student3` sur `127.0.0.3`, alias `localhost3`. Les ports, eux, sont les mêmes pour tout le monde (8080 pour les UIs). Deux variables déjà présentes dans votre shell portent cette adresse : `$PF_ADDR` (celle que vous passez à `--address`) et `$PF_HOST` (celle des URLs). `open-ui.sh` affiche vos URLs et la commande de tunnel SSH à lancer depuis votre poste.

L'installation prend quelques minutes (téléchargement des images). Pendant ce temps, regardez ce que fait le script : il crée un cluster Kind (`ktbx create -s`), pré-télécharge les images de la démo sur la machine et les injecte dans le cluster (`scripts/preload-images.sh`), puis installe le chart Helm `open-telemetry/opentelemetry-demo` dans le namespace `otel-demo` — c'est la [démo officielle OpenTelemetry](https://opentelemetry.io/ecosystem/demo/), l'« Astronomy Shop ».

{{%expand "Que contient le namespace otel-demo ?" %}}
Le chart Helm déploie :
* la **boutique** : une vingtaine de micro-services polyglottes (Go, Java, Python, .NET, Rust...), Kafka, PostgreSQL, Valkey ;
* le **load generator**, qui simule des clients en continu — vous aurez donc toujours des données à observer ;
* la **chaîne d'observabilité** : collecteur OpenTelemetry (DaemonSet), Jaeger, Prometheus, OpenSearch et Grafana, déjà câblés entre eux.

Le détail service par service (langage, type d'instrumentation utilisée) : [Language feature reference](https://opentelemetry.io/docs/demo/#language-feature-reference).
{{% /expand%}}

2.  **Vérifier que tous les pods sont démarrés :**

```bash
kubectl get pods -n otel-demo
```

> `kubectl get pods -n otel-demo` liste les conteneurs qui tournent dans le namespace `otel-demo`. Tous doivent être en état `Running` avec `READY 1/1`.

Combien de micro-services applicatifs identifiez-vous ? Lesquels sont écrits en **Java** ?

{{%expand "Réponse" %}}
Une vingtaine de pods applicatifs. Les services **Java** sont :
* `ad` (Ad Service) — instrumenté avec l'**agent Java** OpenTelemetry : c'est notre service de référence pour le Lab 2 ;
* `fraud-detection` (Kotlin, JVM également).

```bash
kubectl get pods -n otel-demo -o wide
```
{{% /expand%}}

3.  **Accéder aux interfaces web :**

```bash
./scripts/open-ui.sh
```

> Ce script fait un `kubectl port-forward` vers le proxy frontal de la démo : toutes les UIs sont alors accessibles sur le port **8080**, derrière lequel le proxy route vers Grafana, Jaeger et le reste. Le script affiche vos URLs exactes.

* La boutique : [http://localhost:8080/](http://localhost:8080/)
* Grafana : [http://localhost:8080/grafana/](http://localhost:8080/grafana/)
* Jaeger : [http://localhost:8080/jaeger/ui/](http://localhost:8080/jaeger/ui/)
* Load generator : [http://localhost:8080/loadgen/](http://localhost:8080/loadgen/)

4.  **Générer votre propre trafic :**

Ouvrez la boutique, choisissez un télescope et passez une commande complète (panier → checkout).

⚠️ Vous n'êtes pas seul à commander : la démo embarque un **load generator** ([Locust](https://locust.io/), 10 utilisateurs virtuels démarrés automatiquement) qui navigue et passe des commandes **en continu**, pour que la plateforme ait toujours des données à observer. Il génère à la fois des requêtes HTTP et du trafic navigateur réel (Playwright). Résultat : Jaeger contient en permanence des dizaines de traces de checkout qui ne sont pas les vôtres — et elles ressemblent beaucoup aux vôtres.

Pour isoler votre commande, mettez le générateur en pause avant de commander :

* ouvrez le load generator ([http://localhost:8080/loadgen/](http://localhost:8080/loadgen/)), cliquez sur **Stop** ;
* attendez ~30 s (le temps que les requêtes en cours se terminent), puis notez l'heure et passez votre commande ;
* relancez le générateur (**Start swarming**) après l'étape 5 : les labs suivants ont besoin de ce trafic de fond.

5.  **Retrouver votre commande dans Jaeger :**

Dans Jaeger, cherchez les traces du service `checkout` (opération `oteldemo.CheckoutService/PlaceOrder`) et ouvrez la plus récente — celle dont l'horodatage correspond à votre clic.

> 💡 Si vous n'avez pas arrêté le load generator, triez par *Most Recent* et repérez la trace à l'heure de votre commande — c'est le critère le plus fiable. Indice complémentaire : les traces issues des requêtes HTTP du générateur contiennent un span du service **`load-generator`** (visible dans les badges de services de la liste de résultats), que les vôtres n'ont pas. Attention, ce n'est pas infaillible : le générateur pilote aussi un vrai navigateur, dont les traces partent comme les vôtres du `frontend`. D'où l'intérêt de l'arrêter.

Combien de services différents cette trace traverse-t-elle ? Que représente chaque barre horizontale ?

{{%expand "Réponse" %}}
La trace de checkout traverse typiquement **8 à 10 services** : `frontend` → `checkout` → `cart`, `currency`, `payment`, `shipping`, `email`, `product-catalog`... et passe même par **Kafka** vers `accounting` et `fraud-detection`.

Chaque barre horizontale est un **span** : une opération unitaire (requête HTTP, appel gRPC, requête SQL, publication Kafka) avec sa durée. L'ensemble des spans liés forme la **trace** : le parcours complet de la requête à travers le système distribué.
{{% /expand%}}

6.  **Une première métrique dans Grafana :**

Dans Grafana, ouvrez le dashboard **Demo Dashboard** (dossier `General`). Observez le taux de requêtes et les latences par service — c'est le trafic du load generator que vous voyez en direct.

7.  **Le fil rouge — un service invisible :**

L'équipe Java vient de livrer le micro-service **`review-service`** (avis produits). Cherchez-le dans Jaeger (liste des services) et dans Grafana.

{{%expand "Réponse" %}}
Il n'y est pas ! `review-service` n'est même pas encore déployé — et surtout, il n'est **pas instrumenté** : même déployé, il n'émettrait aucune télémétrie.

C'est tout l'objet des prochains labs : le rendre observable de bout en bout, **sans modifier son code** pour commencer (Lab 2).
{{% /expand%}}

## Livrable

Une capture d'écran d'une trace de checkout de bout en bout dans Jaeger (avec les spans Kafka visibles).
