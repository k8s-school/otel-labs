---
title: 'Pense-bête kubectl'
date: 2026-07-08T19:00:00+02:00
draft: false
weight: 20
tags: ["kubernetes", "kubectl", "formation", "pre-requis"]
---

Vous n'avez **pas besoin de connaître Kubernetes** pour suivre cette formation :
toutes les commandes sont fournies dans les labs. Ce pense-bête sert juste à
comprendre ce que vous tapez et à vous dépanner.

## Le vocabulaire minimal

| Terme | Ce que c'est (en une phrase) |
|---|---|
| **Cluster** | La machine (ici **Kind**, un Kubernetes local dans Docker) qui fait tourner tout. |
| **Namespace** | Un « dossier » qui regroupe des ressources. Toute la démo vit dans `otel-demo`. |
| **Pod** | La plus petite unité qui tourne : un (ou plusieurs) conteneur(s). ≈ « un micro-service en cours d'exécution ». |
| **Deployment** | Recette qui garde N pods d'un service en vie (ex. `review-service`). |
| **DaemonSet** | Comme un Deployment, mais un pod **par nœud** (ex. le collecteur OpenTelemetry). |
| **Service (svc)** | Une adresse réseau stable pour joindre des pods (ex. `grafana`, `jaeger-query`). |

> ⚠️ Presque toutes les commandes prennent `-n otel-demo` (le namespace de la démo).
> Si une commande ne renvoie rien, c'est souvent qu'il manque le `-n otel-demo`.

## Regarder ce qui tourne

```bash
# Lister les pods de la démo (colonne STATUS = Running, READY = 1/1 attendu)
kubectl get pods -n otel-demo

# Idem, avec le nœud et l'IP de chaque pod
kubectl get pods -n otel-demo -o wide

# Lister les services (adresses réseau internes)
kubectl get svc -n otel-demo

# Infos générales sur le cluster
kubectl cluster-info
```

Astuce : ajoutez `-w` (« watch ») pour suivre en direct, `Ctrl-C` pour quitter :

```bash
kubectl get pods -n otel-demo -w
```

## Diagnostiquer un pod

```bash
# Détail complet d'un pod (événements, causes de crash en bas de sortie)
kubectl describe pod <nom-du-pod> -n otel-demo

# Voir les logs d'un déploiement (ajoutez -f pour suivre en direct)
kubectl logs -n otel-demo deployment/review-service
kubectl logs -n otel-demo deployment/review-service -f

# Ouvrir un shell dans un pod
kubectl exec -it -n otel-demo deployment/review-service -- bash
```

## Accéder à une UI depuis votre poste (port-forward)

Les services (Grafana, Jaeger...) tournent **dans** le cluster. `port-forward`
crée un tunnel entre un port de votre machine et le service :

```bash
# http://localhost:8080 -> service grafana, port 80, dans le cluster
kubectl port-forward -n otel-demo svc/grafana 8080:80
```

Laissez la commande tournée (elle bloque le terminal), ouvrez le navigateur,
puis `Ctrl-C` pour couper le tunnel.

> 🏫 Sur un serveur partagé, utilisez toujours les URLs affichées par
> `./scripts/open-ui.sh` (vos ports sont décalés).

## Attendre qu'un déploiement soit prêt

Après un changement de config, ces commandes rendent la main **une fois** le
service redémarré (bien pratique dans les scripts) :

```bash
kubectl rollout status -n otel-demo deployment/review-service
kubectl rollout status -n otel-demo daemonset/otel-collector-agent
```

## Modifier / appliquer de la configuration

```bash
# Injecter une variable d'environnement (déclenche un redémarrage du pod)
kubectl set env -n otel-demo deployment/review-service OTEL_LOG_LEVEL=debug

# Afficher un ConfigMap (config d'un composant)
kubectl get configmap otel-collector-agent -n otel-demo -o yaml

# Appliquer un fichier de manifeste YAML
kubectl apply -n otel-demo -f mon-fichier.yaml
```

## Se dépanner soi-même

| Symptôme | Réflexe |
|---|---|
| `No resources found` | Il manque probablement `-n otel-demo`. |
| Pod en `Pending` | Le cluster manque de ressources : `kubectl describe pod <nom> -n otel-demo`. |
| Pod en `CrashLoopBackOff` | Il redémarre en boucle : lisez les logs `kubectl logs <nom> -n otel-demo`. |
| `port-forward` coupe tout seul | Le pod a redémarré : relancez la commande. |
| Une UI ne répond pas | Vérifiez que le `port-forward` tourne encore dans son terminal. |

> 💡 Complétion automatique : tapez le début d'un nom de pod puis `Tab`.
> Pensez aussi à l'alias `k=kubectl` si vous le souhaitez : `alias k=kubectl`.
