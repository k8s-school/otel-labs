# Dimensionnement du serveur pour 12 participants

*Note ouverte le 2026-09-03, à trancher avant la session Michelin.*

## Le problème

Le serveur actuel est une **GP1-M** (16 vCPU, 64 Gio de RAM, disque de 100 Go —
`root_volume_size_gb` dans `../k8s-server/provisioning/tofu/envs/otel.tfvars`).

Une stack participant coûte, mesuré sur un lab qui tourne (26 pods de démo +
load generator), et documenté dans `group_vars/otel.yml` :

| Ressource | Par stack |
|---|---|
| RAM | ~6,4 Gio |
| vCPU | ~1,7 |
| Images dans le nœud kind | ~11 Go |

Pour **12 participants avec une stack chacun** :

* RAM : 12 × 6,4 = **77 Gio** — la machine en a 64. Ça ne passe pas.
* Disque : 12 × 11 = **132 Go** — la machine en a 100. Ça ne passe pas non plus,
  et c'est le disque qui lâche en premier.

Le plafond de la GP1-M est de **7 à 8 stacks simultanées**.

## L'idée de mutualiser (1 stack pour 4)

Elle règle la ressource — 3 stacks = 19 Gio de RAM et 33 Go de disque, très
confortable — mais elle **casse l'isolation que les labs supposent**. À vérifier
avant de s'y engager :

* **Labs 3, 6, 7 et 8** appliquent tous un `helm upgrade` sur le collecteur, en
  empilant des fichiers de values. À quatre sur une stack, l'upgrade de l'un
  redémarre le collecteur des trois autres, et deux participants à des étapes
  différentes se battent sur le jeu de values.
* **Lab 2** : `./scripts/deploy.sh` déploie `review-service` dans le namespace
  `otel-demo`. Quatre participants s'écrasent mutuellement l'image et le
  déploiement.
* **Lab 4** : la règle d'alerte a un `uid` fixe (`otel-training-p95`) et le
  dashboard un nom fixe. Deuxième participant = collision.
* **Lab 8** : le masquage PII s'applique au collecteur, donc à tout le groupe.

Autrement dit, mutualiser à 4 demande de retoucher les labs, pas seulement la
machine.

## Les options, du moins cher au plus simple

1. **Binômes — 6 stacks sur la machine actuelle.** 6 × 6,4 = 38 Gio de RAM et
   6 × 11 = 66 Go de disque : ça tient sans rien changer. Les frictions
   ci-dessus restent, mais à deux elles se gèrent en se parlant, et le
   pair programming est courant en formation.
2. **Monter le disque à 200 Go**, une ligne dans `otel.tfvars`. Lève la
   contrainte disque, mais la RAM plafonne toujours à ~9 stacks. Insuffisant
   seul pour 12.
3. **Passer en GP1-L** (32 vCPU, 128 Gio, 0,774 €/h contre 0,384) + disque à
   200 Go. 12 × 6,4 = 77 Gio tient dans 128, et 132 Go de disque dans 200.
   **C'est la seule option qui donne une stack par participant sans toucher aux
   labs.** Coût : environ le double, sur deux jours.
4. **Deux serveurs de 6.** Double le travail de provisioning et de suivi en
   salle, pour un coût voisin de l'option 3.

## Recommandation provisoire

L'option **3 (GP1-L + disque 200 Go)** si le budget le permet : elle préserve le
modèle « une stack par participant », qui est ce que les labs supposent partout,
et n'exige aucune réécriture. L'option **1 (binômes)** est le repli gratuit.

À décider avant le provisioning définitif — `instance_type` et
`root_volume_size_gb` se changent en une ligne, mais imposent un
`make down` / `make up`, donc pas en pleine session.
