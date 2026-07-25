# Mode serveur partagé (formateur)

Un seul serveur héberge **un cluster Kind par participant**. L'isolation
pédagogique est totale (chacun casse/répare *son* collecteur), mais le cache
Docker est partagé : le premier build Maven profite à tous.

## Dimensionnement (jusqu'à 9 participants)

| Ressource | Valeur |
|---|---|
| RAM | 128 Go (96 Go minimum) — ~6-8 Go/participant |
| CPU | 32+ vCPU |
| Disque | 300+ Go SSD/NVMe — ~15-20 Go/participant (images dans les nœuds Kind) |
| Prérequis | docker, **kind ≥ v0.27**, ktbx, helm, kubectl, git, go |

## Provisioning

```bash
sudo ./scripts/setup-students.sh 9
```

Pour chaque `studentN`, le script :
1. crée le compte Unix (groupe `docker`) ;
2. exporte `CLUSTER_NAME=studentN` et `PORT_OFFSET=N` dans son `.bashrc`
   (tous les scripts de la formation lisent ces variables via `scripts/env.sh`) ;
3. clone le dépôt de la formation dans son home ;
4. crée son cluster Kind (`ktbx create -s -n studentN`) et installe son kubeconfig ;
5. précharge les images de la démo dans ce cluster (`scripts/preload-images.sh`) :
   le téléchargement n'a lieu que pour le premier participant, les suivants
   réutilisent le cache Docker de la machine.

⚠️ La **stack OpenTelemetry n'est pas installée** : c'est l'objet du lab 1,
chaque participant lance `./scripts/up.sh` (sans `-c`) sur son cluster. Grâce
au préchargement, l'installation ne retélécharge rien.

## Ports par participant

`PORT_OFFSET` décale tous les ports locaux du numéro du participant :
`student3` a l'UI sur `8083` (808**3**), l'API review-service sur `8093`,
Prometheus sur `9093`, OpenSearch sur `9203`.
`./scripts/open-ui.sh` affiche toujours les **vraies** URLs du participant.

⚠️ Limite à **9 participants** : au-delà, `808<N>` empiéterait sur la plage
`809x` du review-service. Pour un groupe plus grand, repasser à un offset plus
large (`PORT_OFFSET=N×100`) dans `setup-students.sh`.

⚠️ Les énoncés des labs utilisent les ports par défaut (8080, 8090...) :
en mode partagé, demander aux participants de remplacer par les ports
affichés par `open-ui.sh` (ou d'utiliser `$UI_PORT`, `$APP_PORT`... exportés
dans leur shell).

## Accès aux UIs

Tunnel SSH depuis le poste du participant :

```bash
ssh -L 8081:localhost:8081 student1@<serveur>   # puis http://localhost:8081/
```

(VS Code Remote-SSH forwarde les ports automatiquement.)

## Points d'attention

- **Docker partagé** : un participant peut voir/supprimer les conteneurs des
  autres (`docker rm` malheureux = cluster voisin détruit). Acceptable en
  formation encadrée ; sinon prévoir Docker rootless par compte.
- **Lab 1 raccourci** : le cluster existe déjà — les participants font
  `./scripts/up.sh` (sans `-c`), qui installe la démo sur *leur* cluster.
- Préparer le serveur **la veille** : `setup-students.sh` télécharge et charge
  toutes les images dans chaque cluster (compter ~5 Go de téléchargement, puis
  quelques minutes de `kind load` par participant).
- Vérifier le préchargement d'un cluster : `./scripts/preload-images.sh -n student1`
  (ré-exécutable, il ne recharge que ce qui manque) ; `-l` affiche la liste des
  images utilisées.
