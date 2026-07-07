# Mode serveur partagé (formateur)

Un seul serveur héberge **un cluster Kind par participant**. L'isolation
pédagogique est totale (chacun casse/répare *son* collecteur), mais le cache
Docker est partagé : le premier build Maven profite à tous.

## Dimensionnement (10–12 participants)

| Ressource | Valeur |
|---|---|
| RAM | 128 Go (96 Go minimum) — ~6-8 Go/participant |
| CPU | 32+ vCPU |
| Disque | 300+ Go SSD/NVMe — ~15-20 Go/participant (images dans les nœuds Kind) |
| Prérequis | docker, **kind ≥ v0.27**, ktbx, helm, kubectl, git, go |

## Provisioning

```bash
sudo ./scripts/setup-students.sh 10
```

Pour chaque `studentN`, le script :
1. crée le compte Unix (groupe `docker`) ;
2. exporte `CLUSTER_NAME=studentN` et `PORT_OFFSET=N×100` dans son `.bashrc`
   (tous les scripts de la formation lisent ces variables via `scripts/env.sh`) ;
3. clone le dépôt de la formation dans son home ;
4. crée son cluster Kind (`ktbx create -s -n studentN`) et installe son kubeconfig.

## Ports par participant

`PORT_OFFSET` décale tous les ports locaux : `student3` a l'UI sur `8380`
(8080+300), l'API review-service sur `8390`, Prometheus sur `9390`...
`./scripts/open-ui.sh` affiche toujours les **vraies** URLs du participant.

⚠️ Les énoncés des labs utilisent les ports par défaut (8080, 8090...) :
en mode partagé, demander aux participants de remplacer par les ports
affichés par `open-ui.sh` (ou d'utiliser `$UI_PORT`, `$APP_PORT`... exportés
dans leur shell).

## Accès aux UIs

Tunnel SSH depuis le poste du participant :

```bash
ssh -L 8180:localhost:8180 student1@<serveur>   # puis http://localhost:8180/
```

(VS Code Remote-SSH forwarde les ports automatiquement.)

## Points d'attention

- **Docker partagé** : un participant peut voir/supprimer les conteneurs des
  autres (`docker rm` malheureux = cluster voisin détruit). Acceptable en
  formation encadrée ; sinon prévoir Docker rootless par compte.
- **Lab 1 raccourci** : le cluster existe déjà — les participants font
  `./scripts/up.sh` (sans `-c`), qui installe la démo sur *leur* cluster.
- Préparer le serveur **la veille** : lancer `setup-students.sh` puis un
  `up.sh` sur un compte pour pré-tirer toutes les images de la démo.
