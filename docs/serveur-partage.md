# Mode serveur partagé (formateur)

Un seul serveur héberge **un cluster Kind par participant**. L'isolation
pédagogique est totale (chacun casse/répare *son* collecteur), et le cache
Docker est partagé : les images de la démo ne sont téléchargées qu'une fois
pour toute la salle.

## Provisioning

Le serveur n'est **pas** provisionné depuis ce dépôt, mais depuis
[`k8s-school/k8s-server`](https://github.com/k8s-school/k8s-server)
(OpenTofu + Ansible) :

```bash
cd k8s-server/provisioning
make provision FLAVOR=otel     # = make up (VM Scaleway) + make configure (Ansible)
```

Ansible (`ansible/site.yml`, `group_vars/otel.yml`) prépare pour chaque
`student<N>` :

1. le compte Unix (groupes `docker`, `adm`) et son mot de passe ;
2. le dépôt de la formation cloné dans `~/.ktbx/homefs/otel` ;
3. son environnement dans `.bashrc` : `CLUSTER_NAME=student<N>`,
   `PF_ADDR=127.0.0.<N>`, `PF_HOST=localhost<N>` ;
4. l'entrée `/etc/hosts` correspondante (`127.0.0.3 localhost3`) ;
5. l'accès navigateur [Apache Guacamole](https://guacamole.apache.org/)
   (`guacamole_enabled: true`), une connexion par participant.

Côté cluster, Ansible ne fait qu'installer Helm (`training_action: helm_only`).

⚠️ **Ni le cluster Kind ni la stack OpenTelemetry ne sont créés à l'avance** :
c'est l'objet du lab 1, où chaque participant lance `./scripts/up.sh -c` sur
son compte — exactement la même commande que sur un poste individuel. Le
premier démarrage télécharge les images (~5 Go) ; les suivants réutilisent le
cache Docker de la machine.

## Un port pour tous, une adresse par participant

Les énoncés des labs utilisent les mêmes ports pour tout le monde — 8080 pour
les UIs, 8090 pour le `review-service`, 9090 pour Prometheus, 9200 pour
OpenSearch, 55679 pour les zPages. Ce qui distingue les participants, c'est
l'**adresse d'écoute** de leurs port-forwards : `student3` binde `127.0.0.3`
(alias `localhost3`), `student4` binde `127.0.0.4`, etc. Tout `127.0.0.0/8`
est routé vers `lo` sous Linux : rien à configurer, et jusqu'à 199 participants
sans collision.

Les participants ne tapent aucun `port-forward` : `scripts/open-ui.sh` les
ouvre tous avec le bon `--address $PF_ADDR`, et les énoncés ne parlent que
d'URLs bâties sur `$PF_HOST` :

```bash
curl http://$PF_HOST:9090/api/v1/label/__name__/values
```

`scripts/env.sh` déduit ces deux variables du nom de compte quand elles ne sont
pas déjà exportées — un shell non interactif (`ssh student3@serveur '…'`) reste
donc correct. Le compte `trainer` a sa propre adresse, `127.0.0.200`, pour ne
pas entrer en conflit avec `student1` lors des démonstrations.

## Accès aux UIs

* **Guacamole** : bureau ou terminal dans le navigateur, sur
  `https://training.k8s-school.fr/` — le participant y ouvre
  `http://localhost3:8080/` directement.
* **Tunnel SSH** depuis le poste du participant, l'URL redevient `localhost` :

```bash
ssh -L 8080:127.0.0.3:8080 student3@<serveur>   # puis http://localhost:8080/
```

`./scripts/open-ui.sh` ouvre tous les accès d'un coup — proxy frontal (UIs),
Prometheus, `review-service`, OpenSearch, zPages du collecteur — puis rend la
main. Il libère d'abord les ports de votre adresse, travaille en arrière-plan
et rouvre chaque accès quand son pod est remplacé ; `./scripts/open-ui.sh -s`
ferme tout, et `scripts/down.sh` le fait avant de supprimer le cluster.
Journal : `~/.cache/otel-labs/port-forward.log`.

## Dimensionnement

Mesuré sur un lab en fonctionnement (26 pods de la démo + load generator) :

| Ressource | Par participant |
|---|---|
| RAM | ~6,4 Gio (+ ~1 Gio si bureau Guacamole/Firefox) |
| CPU | ~1,7 vCPU en régime, bien plus pendant le démarrage |
| Disque | ~11 Go d'images dans le nœud Kind, + la croissance de Prometheus/OpenSearch |

La VM par défaut (`envs/otel.tfvars`) est une **GP1-M : 16 vCPU / 64 Gio /
100 Go**. Elle tient donc **~8 participants** côté RAM, mais le disque sature
avant : porter `root_volume_size_gb` à ~250 Go pour une salle complète (GP1-M
accepte jusqu'à 600 Go). Au-delà d'une dizaine de participants, passer en
GP1-L (32 vCPU / 128 Gio).

Prérequis logiciels sur le serveur : docker, **kind ≥ v0.27**, ktbx, helm,
kubectl, git, go — tous cuits dans l'image dorée par Packer
(`make create-image FLAVOR=otel`).

## Points d'attention

- **Docker partagé** : un participant peut voir/supprimer les conteneurs des
  autres (`docker rm` malheureux = cluster voisin détruit). Acceptable en
  formation encadrée ; sinon prévoir Docker rootless par compte.
- **Démarrages simultanés** : 8 `up.sh -c` en même temps saturent le CPU et le
  réseau. Faire démarrer le lab 1 par vagues, ou lancer un `up.sh` la veille
  sur un compte pour amorcer le cache Docker.
- **Vérifier le préchargement d'un cluster** :
  `./scripts/preload-images.sh -n student1` (ré-exécutable, il ne charge que ce
  qui manque) ; `-l` affiche la liste des images utilisées.
