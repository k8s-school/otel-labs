# Stress test du serveur de formation

Scripts pour rejouer la simulation d'une session — N stagiaires qui déroulent
les labs en même temps sur le serveur Guacamole — et les stress tests qui
cherchent les limites de la machine. Le compte rendu de la campagne du
2026-09-12 (GP1-L, 9 stacks) est dans [RAPPORT.md](RAPPORT.md).

## Mise en place

```bash
cd ../k8s-server/provisioning
make create-image FLAVOR=otel                # une fois, ~7 min
make provision FLAVOR=otel NB_USERS=9        # GP1-L, student1-9 + trainer
IP=$(make ip FLAVOR=otel | tail -1)
ssh root@$IP mkdir -p /root/sim/log
scp infra-stress-test/*.sh ../k8s-server/util/sizing-report.sh root@$IP:/root/sim/
ssh root@$IP 'chmod 755 /root/sim/*.sh; nohup /root/sim/monitor.sh /root/sim/monitor.csv >/dev/null 2>&1 < /dev/null & disown'
```

Tous les scripts se lancent **en root sur le serveur**, sauf `guac-load.py`
et `make-accounts.sh`, qui tournent depuis le poste du formateur. `USERS=...`
en variable d'environnement change la liste des comptes simulés (par défaut
`trainer student1 … student8`).

## La simulation, dans l'ordre des labs

| Commande | Ce qu'elle rejoue | Ce qu'on y mesure |
|---|---|---|
| `phase.sh up` | lab 1 : `up.sh -c` puis `open-ui.sh`, tous en parallèle | le pic d'I/O du `kind load`, la durée jusqu'aux pods prêts |
| `phase.sh deploy` | lab 2 : `deploy.sh` ×N | le pic CPU/RAM des builds Maven |
| `phase.sh reviews` | lab 6 : `generate-reviews.sh 600` ×N | le régime établi sous trafic |
| `phase.sh lab8` | lab 8 : POST fautif, 30 GET, attente Jaeger, requête OpenSearch | la latence de bout en bout (agent inactif après `deploy.sh` : les timeouts Jaeger sont attendus) |
| `phase.sh check` | — | contexte, pods prêts, port-forwards, Grafana, par compte |
| `phase.sh openui` | — | relance `open-ui.sh` partout |

Les logs sont dans `/root/sim/log/<phase>-<user>.log`, durée et code de sortie
en dernière ligne.

## Les bureaux Guacamole

```bash
# sur le poste du formateur : lit le vault, écrit accounts.txt, n'affiche rien
./make-accounts.sh 8
python3 -m venv venv && ./venv/bin/pip install websockets requests
./venv/bin/python guac-load.py https://training.k8s-school.fr accounts.txt 1800
# sur le serveur, une fois les sessions XFCE ouvertes : un Firefox sur Grafana par bureau
./desktops.sh start ; ./desktops.sh list ; ./desktops.sh stop
```

`guac-load.py` ouvre un tunnel WebSocket par compte, comme le navigateur d'un
stagiaire : c'est ce flux que guacd encode, donc le vrai coût CPU de Guacamole.

## Les stress tests

| Commande | Question posée |
|---|---|
| `stress.sh io` | combien d'IOPS reste-t-il aux stacks ? (fio, 4k aléatoire puis 1M séquentiel) |
| `stress.sh cpu` + `stress.sh probe` à côté | les UIs répondent-elles quand les 32 vCPU sont pris ? |
| `stress.sh mem` | que se passe-t-il si un stagiaire mange 80 % de la RAM « disponible » ? |
| `stress.sh rebuild` | de combien grossissent les image stores à chaque `deploy.sh` ? |
| `stress.sh probe` | latence Grafana / Jaeger / review-service pour chaque compte |

## Le diagnostic

| Commande | Sert à |
|---|---|
| `monitor.sh out.csv` | échantillonner load, RAM, I/O, PSI, conntrack… toutes les 13 s (pas un diviseur du cycle de 40 s de la stack) |
| `iostat.sh` | IOPS et débit du disque racine sur 10 s |
| `topio.sh` | les processus qui lisent/écrivent le plus sur le disque |
| `thrash-scan.sh [seuil %]` | les conteneurs collés à leur limite mémoire, avec leur taux de *refault* — c'est le signal du thrashing |
| `converge.sh` | load, IOPS, PSI et pods prêts par compte, une ligne par minute |
| `limits.sh` | limites noyau (inotify, threads, conntrack…) : usage / plafond |
| `sizing-report.sh` | le rapport de `../k8s-server/util`, RAM par stack et PSS par bureau |

## Les remèdes

| Commande | Quand |
|---|---|
| `fix-thrash.sh "<motif>" <limite>` | un service thrashe et les API servers ne répondent plus : relève `memory.max` dans le cgroup, effet immédiat |
| `apply-limits.sh [deploy req lim]` | pousser les limites de `manifests/values-training.yaml` sur les N clusters sans attendre un `up.sh` |
