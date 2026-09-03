---
marp: true
theme: custom-theme
paginate: true
backgroundColor: #ffffff
---

# Formation OpenTelemetry

## Chapitre 9 — Framework Spring *(facultatif)*

<img src="images/logo.svg" alt="K8s School Logo" width="50%">

---

## Micrometer, en une slide

- Une **bibliothèque Java** née en 2017 dans l'écosystème Spring, avant OTel
- Le code mesure **sans savoir où ça part** : on déclare un chronomètre, on l'appelle —
  le `Timer` du `review-service` est un exemple réel
  ([`ReviewController.java:68`](https://github.com/k8s-school/otel-labs/blob/main/apps/review-service/src/main/java/fr/k8sschool/reviews/ReviewController.java#L68))
- Le **registry** décide où partent les mesures. On en change par une ligne de
  **dépendance**, jamais en touchant au code :

| Dépendance ajoutée | Destination |
|---|---|
| *aucune* (le défaut, cas de `review-service`) | la mémoire — rien n'est exporté |
| `micrometer-registry-prometheus` | un `/actuator/prometheus` à scraper |
| `micrometer-registry-otlp` | un collecteur, en OTLP |
- Comme OpenTelemetry, il fournit **l'API et les exporters**, et ne **stocke rien** —
  d'où la question de ce chapitre : sur les métriques, les deux font le même travail

---

## Deux mondes qui convergent

- Côté Spring, le stack s'est complété :
  **Micrometer** (métriques) puis **Micrometer Tracing** (traces,
  successeur de Spring Cloud Sleuth) — Spring couvre donc les deux signaux
- Côté OTel : agent, starter, SDK — et les trois signaux, dans tous les langages
- Deux façades pour le même besoin : **laquelle appeler depuis son code ?**
- Bonne nouvelle : ce ne sont **pas** deux backends concurrents,
  les deux savent parler **OTLP**

---

## Logs : rien à faire

- Spring Boot écrit ses logs avec **Logback**, et OTel a un appender pour lui
  (`opentelemetry-logback-appender`) : chaque événement → un LogRecord OTLP
- **L'agent l'injecte tout seul**, le **starter** l'apporte en dépendance :
  dans les deux cas, **aucun fichier de configuration à écrire** —
  `review-service` n'a d'ailleurs pas de fichier Logback
- Le `trace_id` courant est attaché au passage : la **corrélation log ↔ trace** est gratuite
- On ne déclare l'appender à la main (`logback-spring.xml`) que sans agent **ni** starter —
  et il faut alors construire le SDK soi-même. Cas rare (chapitre 5)
- ⚠️ **Micrometer ne fait pas les logs** : ni API, ni exporter. Sur ce signal, il n'y a donc **pas de choix à faire** — c'est OpenTelemetry, agent ou starter

---

## Métriques : trois chemins, un seul collecteur

| Chemin | Ce qu'on ajoute | Quand le choisir |
|---|---|---|
| **Agent OTel** | rien dans le code | le cas du Lab 6 : un flag, et les métriques Micrometer existantes partent en OTLP |
| **Starter OTel** | une dépendance Spring | quand on ne peut pas poser d'agent (`-javaagent` interdit, image figée) : le SDK est **compilé dans l'application** |
| **Micrometer seul** | `micrometer-registry-otlp` | pas d'OTel du tout : Micrometer parle OTLP directement |

- Le troisième chemin est le plus surprenant : on peut envoyer de l'OTLP à un
  collecteur **sans aucune dépendance OpenTelemetry** — c'est un simple registry
- Le collecteur reçoit la même chose dans les trois cas

---

## Traces : l'API Observation

- Sur les **métriques**, les deux API font la même chose — le Lab 6 les met côte à côte
  sur le même appel : `Timer` Micrometer d'un côté, compteur + histogramme OTel de
  l'autre ([`ReviewController.java:117-127`](https://github.com/k8s-school/otel-labs/blob/main/apps/review-service/src/main/java/fr/k8sschool/reviews/ReviewController.java#L117-L127))
- La différence est ailleurs : avec l'**API OTel**, chaque signal se code **séparément**,
  et à un autre endroit — le span de ce même travail est créé par `@WithSpan`
  dans une autre classe ([`ProductCatalogClient.java:40`](https://github.com/k8s-school/otel-labs/blob/main/apps/review-service/src/main/java/fr/k8sschool/reviews/ProductCatalogClient.java#L40), Lab 7)
- **`Observation`** (Micrometer) réunit les deux : **un seul appel** produit le span,
  le timer et les logs corrélés — et dessous c'est **OpenTelemetry** qui travaille,
  via `micrometer-tracing-bridge-otel` : API Spring, moteur OTel, sortie OTLP
- Spring documente `Observation` comme l'API à appeler, et auto-configure **OTel + OTLP** pour la sortie ([Tracing, doc Spring Boot](https://docs.spring.io/spring-boot/reference/actuator/tracing.html))
- ➡ [API Java OTel](https://opentelemetry.io/docs/languages/java/api/) · [API Observation](https://docs.micrometer.io/micrometer/reference/observation.html) · [Micrometer Tracing](https://docs.micrometer.io/tracing/reference/index.html)

---

## Quelle stratégie retenir ?

- **Application Spring existante, déjà instrumentée Micrometer** : ne réécrivez rien.
  L'agent OTel fait le pont (Lab 6), et vous gagnez les traces sans y toucher
- **Nouveau projet, uniquement Java/Spring** : `Observation` est défendable —
  un appel pour deux signaux, et une API que l'équipe connaît déjà
- **Nouveau projet, ou parc polyglotte** (le cas de l'Astronomy Shop) :
  **API OpenTelemetry**. C'est le choix par défaut, pour trois raisons :
  - les **mêmes concepts dans tous les langages** — Micrometer n'existe qu'en Java
  - les **trois signaux** dans une seule API, logs compris
  - un **standard CNCF**, pas la bibliothèque d'un framework
- Dans tous les cas : **OTLP vers un collecteur**, conventions sémantiques —
  le backend ne voit pas la différence, et le choix reste réversible
