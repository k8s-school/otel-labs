# Formation OpenTelemetry — Michelin DevOps
## Programme détaillé formateur (2 jours)

> Run-sheet minuté à usage du formateur. Ratio labs / théorie : **60 % de labs** (425 min de labs pour 280 min de théorie), durées calées sur des mesures — voir la note en fin de document.
> Base technique : cluster **Kind** + **démo officielle OpenTelemetry** (collecteur, Grafana, Jaeger, Prometheus, OpenSearch, Kafka, PostgreSQL, load generator, Ad Service Java) + **micro-service Spring Boot** custom (`review-service`) pour l'instrumentation manuelle.

---

## Principes d'animation

- **La stack tourne dès le Lab 1.** Tout le reste s'appuie dessus. Si elle casse en salle, la journée s'effondre — d'où un Lab 1 en début de J1, entièrement guidé.
- **Le load generator tourne en continu** → les participants voient des données réelles dans Grafana/Jaeger sans avoir à générer du trafic à la main.
- **Chaque lab produit un livrable observable** (un dashboard, une trace, une métrique qui apparaît). On valide visuellement, pas sur du code.
- **Déploiement en 1 ligne** via `./deploy.sh <service>` (`docker build` → `kind load docker-image` → `kubectl apply` → `kubectl rollout status`). Pas de registry.
- **Architecture hybride** : la stack d'observabilité vit dans Kind ; les applis Java des participants peuvent tourner en local/Docker et pousser vers le collecteur (port-forward / NodePort) OU être déployées dans Kind via le script — au choix selon le lab.

---

## Répartition des chapitres

| Jour | Chapitres | Labs |
|------|-----------|------|
| **J1** | 1. Introduction · 2. Zero-code · 3. Collecteur · 4. Grafana | Labs 1 → 4 |
| **J2** | 5. Logs · 6. Métriques · 7. Traces · 8. Sécurité & conformité · 9. Spring (facultatif) · 10. Conclusion | Labs 5 → 8 |

> ⚠️ **Point de vigilance J1** : 4 chapitres + 4 labs en une journée, c'est dense (Introduction et Collecteur sont deux gros blocs théoriques). Le planning ci-dessous compresse la théorie au strict nécessaire et bascule un maximum en live-demo pendant les labs.
>
> **Les deux variables d'ajustement, dans cet ordre** : le **Lab 4.1** (Exemplars) — de la lecture guidée, qui se fait en démo au tableau ou se reporte au Jour 2 — puis l'**étape 1 du Lab 3** (lecture commentée de la configuration), que le lab lui-même désigne comme « à lire à froid ». Ne rognez pas sur le Lab 4 : c'est celui dont le temps est le moins compressible, l'alerte devant réellement passer en `Firing`.

---

# JOUR 1 — Fondations & chaîne de collecte

**Horaires : 9h00–12h30 / 14h00–17h30** · Pauses 15 min matin + après-midi

| Créneau | Durée | Type | Contenu |
|---------|-------|------|---------|
| 09:00 | 20 | Admin | Accueil, tour de table, rappel des objectifs, auto-positionnement |
| 09:20 | 40 | 🖥️ Slides | **Ch.1 — Introduction** |
| 10:00 | 40 | 🧪 **Lab 1** | Démarrage de la stack |
| 10:40 | 15 | ☕ | Pause |
| 10:55 | 40 | 🖥️ Slides | **Ch.2 — Instrumentation zero-code** |
| 11:35 | 50 | 🧪 **Lab 2** | Instrumentation d'un micro-service Java (agent **et** starter) |
| 12:25 | — | 🍽️ | Déjeuner |
| 14:00 | 45 | 🖥️ Slides | **Ch.3 — Collecteur** |
| 14:45 | 55 | 🧪 **Lab 3** | Configuration du collecteur |
| 15:40 | 15 | ☕ | Pause |
| 15:55 | 25 | 🖥️ Slides | **Ch.4 — Grafana** |
| 16:20 | 50 | 🧪 **Lab 4** | Dashboard unifié + alerte déclenchée |
| 17:10 | 15 | 🧪 **Lab 4.1** | Exemplars : du point de métrique à la trace (lecture guidée) |
| 17:25 | 5 | Bilan | Retour sur la journée |

**Labs J1 = 210 min · Théorie = 150 min**, dans une enveloppe utile de 370 min
(10 min de marge).

---

## Chapitre 1 — Introduction *(slides, 40 min)*

**Objectif** : poser le vocabulaire commun et situer OpenTelemetry dans le paysage observabilité.

Contenu slides :
- Observabilité vs monitoring — pourquoi le monitoring classique ne suffit plus
- Les trois piliers : logs, métriques, traces (et comment ils se complètent)
- Du monitoring à l'observabilité 2.0 (corrélation, cardinalité, wide events)
- OpenTelemetry : définition, gouvernance CNCF, ce que le standard couvre / ne couvre pas
- Écosystème & architecture (SDK → collecteur → backend)
- Conventions sémantiques (pourquoi c'est le cœur de la valeur d'OTel)
- Protocole OTLP (gRPC / HTTP, signals unifiés)
- API vs SDK vs distributions vs fournisseurs

### 🧪 Lab 1 — Démarrage de la stack Grafana *(40 min, entièrement guidé)*
**But** : chacun a une stack qui tourne et sait accéder aux UIs.
- Vérifier les prérequis (`kubectl get pods -A`, tous `Running`)
- Accéder à **Grafana**, **Jaeger**, au **frontend** de la démo (port-forward ou ingress)
- Observer le trafic généré par le load generator (une première trace dans Jaeger, une métrique dans Grafana)
- **Livrable** : capture d'une trace de bout en bout dans Jaeger.

---

## Chapitre 2 — Instrumentation zero-code *(slides, 40 min)*

**Objectif** : instrumenter une appli Java sans toucher au code.

Contenu slides :
- Agent Java : principe (Java agent / bytecode instrumentation), installation (`-javaagent`), configuration (variables d'env `OTEL_*`), fonctionnement (auto-instrumentation des libs)
- Spring Boot Starter : quand le préférer à l'agent, installation (dépendance), configuration (`application.properties`)
- Comparaison agent vs starter (couverture, granularité, cas d'usage)

### 🧪 Lab 2 — Instrumentation d'un micro-service Java *(50 min, d'un seul tenant)*
**But** : voir la même appli instrumentée par deux voies.
- **Partie 1** : lancer le micro-service Spring Boot custom avec l'**agent Java** (`-javaagent`), pointer vers le collecteur, générer une requête, retrouver la trace
- **Partie 2** : reprendre l'appli avec le **Spring Boot Starter** à la place de l'agent, comparer les spans produits
- **Point d'appui** : le **Ad Service** de la démo est le service Java auto-instrumenté de référence — l'utiliser comme exemple « qui marche » avant de faire manipuler leur propre service
- **Livrable** : deux traces du même service, une via agent, une via starter.

---

## Chapitre 3 — Collecteur *(slides, 45 min)*

**Objectif** : comprendre le pipeline receivers → processors → exporters et savoir le configurer.

Contenu slides :
- Concepts : rôle du collecteur, pourquoi ne pas exporter directement depuis le SDK
- Installation & modes de déploiement (agent / gateway / DaemonSet — celui de la démo)
- Distributions & fournisseurs (Core, Contrib, distributions vendors)
- **Receivers** : OTLP, Host metrics
- **Processors** : Memory limiter, Batch, Attributes/Resources, Filter, Transform, Resource Detection
- **Langage OTTL** (la brique de transformation — exemples concrets)
- **Connectors** : Forward, Routing
- **Exporters** : Debug, File, OTLP
- **Extensions** : Health check, zPages

### 🧪 Lab 3 — Configuration du collecteur *(55 min)*
**But** : modifier une config collecteur et voir l'effet.
- Éditer la ConfigMap du collecteur (pas de rebuild — juste `kubectl apply` + `rollout restart`)
- Ajouter un receiver **hostmetrics** → collecte des métriques système
- Ajouter la collecte de **métriques produit** (PostgreSQL et/ou Kafka via receiver dédié)
- Ajouter un exporter **debug** + consulter **zPages** pour observer le pipeline
- **Livrable** : métriques système + PostgreSQL visibles dans Prometheus/Grafana.

---

## Chapitre 4 — Grafana *(slides, 25 min)*

**Objectif** : exploiter les données déjà collectées dans un dashboard unifié.

Contenu slides :
- Datasources (Prometheus, Jaeger, OpenSearch — déjà câblées dans la démo)
- Types de visualisations (time series, table, logs panel, trace panel)
- Dashboards (variables, organisation)
- Alerting (principe, règle simple)

### 🧪 Lab 4 — Dashboard unifié *(50 min)*
**But** : rassembler les 3 signaux sur un écran.
- Ajouter une variable (`service_name`) alimentée par les données
- Construire **deux** panels : métriques (Prometheus) et traces (Jaeger)
- Importer le dashboard de référence, qui apporte le p95 et les logs (OpenSearch)
- Installer la règle d'alerte (p95 > 100 ms) et **la faire sonner** en chargeant le service : `Normal` → `Pending` → `Firing`
- **Livrable** : un dashboard « vue service » exporté en JSON (à committer dans le repo).

### 🧪 Lab 4.1 — Exemplars *(15 min, lecture guidée)*
**But** : montrer le chaînon entre métrique et trace, sur le dashboard « Cart Service Exemplars » livré par la démo. Rien à construire : on lit une heatmap, on survole un exemplar, on clique jusqu'à Jaeger.

> 📖 **Lab 4 bonus** (hors séance) : le PromQL des histogrammes — d'où sort un p95, ce qu'il cache, et ce qu'une heatmap montre de plus.

---

# JOUR 2 — Les trois signaux en profondeur

**Horaires : 9h00–12h30 / 14h00–17h30**

| Créneau | Durée | Type | Contenu |
|---------|-------|------|---------|
| 09:00 | 15 | Rappel | Réveil / retour sur J1, questions |
| 09:15 | 30 | 🖥️ Slides | **Ch.5 — Logs** |
| 09:45 | 45 | 🧪 **Lab 5** | Logs applicatives structurées |
| 10:30 | 15 | ☕ | Pause |
| 10:45 | 30 | 🖥️ Slides | **Ch.6 — Métriques** |
| 11:15 | 60 | 🧪 **Lab 6** | Métriques (parties 1 et 2) |
| 12:15 | — | 🍽️ | Déjeuner |
| 14:00 | 30 | 🖥️ Slides | **Ch.7 — Traces** |
| 14:30 | 65 | 🧪 **Lab 7** | Traces & échantillonnage |
| 15:35 | 15 | ☕ | Pause |
| 15:50 | 25 | 🖥️ Slides | **Ch.8 — Sécurité & conformité** |
| 16:15 | 45 | 🧪 **Lab 8** | Masquage & anti-fuite de données sensibles |
| 17:00 | 15 | 🖥️ Slides | **Ch.10 — Conclusion** (Ch.9 Spring en démo si le groupe a de l'avance) |
| 17:15 | 15 | Éval | Questionnaire final + bilan |

**Labs J2 = 215 min · Théorie = 130 min**, dans une enveloppe utile de 360 min
(15 min de marge).

**Ratio global sur les 2 jours ≈ 65 % labs.** Pour monter vers 70 %, basculer une partie de la théorie Ch.5/6/7 en live-demo pendant les labs (voir notes formateur des decks).

> ⚠️ **Point de vigilance J2** : l'ajout du module **Sécurité & conformité** (Ch.8 + Lab 8) densifie l'après-midi. La théorie Ch.5/6/7 est légèrement compressée et le **Ch.9 Spring** passe en démo facultative (fondu dans la conclusion). Le Ch.8 arrive volontairement **après les Traces** : il réutilise le collecteur (Lab 3), les logs (Lab 5), les métriques (Lab 6) et les traces + sampling (Lab 7) comme matière à masquer.

---

## Chapitre 5 — Logs *(slides, 35 min)*

Contenu slides :
- Modèle de données des logs OTel (LogRecord, corrélation trace ↔ log)
- Librairies Java · rappels **SLF4J / Logback**
- SDK **LogProvider**
- Logs structurés (pourquoi, format)
- **Appender Logback** OTel
- Agent Java pour les logs
- Collecteur : receivers **filelog**, **syslog** · processor **Log Transform**
- ⚠️ *Amorce sécurité* : un log = un canal de fuite fréquent (payload, mot de passe). Le masquage via **LogRecordProcessor** est traité au Ch.8.

### 🧪 Lab 5 — Logs structurées *(45 min)*
**But** : émettre → collecter → centraliser.
- Configurer l'appender Logback OTel dans le micro-service
- Produire des logs structurés corrélés aux traces (trace_id dans le log)
- Collecter via le collecteur, visualiser dans OpenSearch/Grafana
- Bonus : receiver **filelog** sur un fichier de log
- **Livrable** : un log corrélé à sa trace, visible dans Grafana (clic log → trace).

---

## Chapitre 6 — Métriques *(slides, 35 min)*

Contenu slides :
- Modèle de données des métriques OTel
- Librairies Java · rappels **Micrometer**
- Types : jauge, compteur, histogramme
- SDK **MeterProvider**
- Annotations
- Agent Java · rappels **Prometheus**
- Collecteur : receiver/exporter **Prometheus** · connectors **count**, **signal to metric**

### 🧪 Lab 6 — Métriques *(60 min, d'un seul tenant)*
**But** : émettre → collecter → grapher.
- **Partie 1** : instrumenter le micro-service avec un compteur + un histogramme (Micrometer ou SDK)
- **Partie 2** : exposer via Prometheus, collecter, grapher dans Grafana ; utiliser un connector **count** pour dériver une métrique depuis des spans
- **Livrable** : un graphe de latence (histogramme) + un compteur métier dans Grafana.

---

## Chapitre 7 — Traces *(slides, 35 min)*

Contenu slides :
- Modèle de données (span, trace, attributs, events, liens)
- SDK **Tracer**
- Contexte de trace & **bagage** (propagation)
- Annotations
- Échantillonnage : **head** vs **tail sampling**, rate limiting
- Collecteur : processor **tail sampling**
- ⚠️ *Amorce sécurité* : un attribut de span (header `Authorization`, `user.email`) peut fuiter des données sensibles. **SpanProcessor** et **Sampler** de masquage/filtrage traités au Ch.8.

### 🧪 Lab 7 — Traces & échantillonnage *(65 min)*
**But** : émettre → collecter → analyser, puis maîtriser le volume.
- Créer un span manuel + un span enfant, propager le contexte entre deux services
- Ajouter du bagage, retrouver la trace dans Jaeger
- Configurer le **tail sampling** dans le collecteur (ex : garder 100 % des traces en erreur, échantillonner le reste)
- **Livrable** : une trace multi-services analysée + une politique de sampling active.

---

## Chapitre 8 — Sécurité & conformité *(slides, 25 min)*

**Objectif** : éviter les fuites de données sensibles et rendre l'observabilité exploitable en contexte **RGPD / sécurité**. Module transverse qui capitalise sur les 3 signaux vus en J2.

Contenu slides :
- **Panorama des fuites fréquentes** (« ce qu'il ne faut PAS faire ») :
  - Tokens **JWT** / header `Authorization` poussés en attribut de span ou dans un log
  - **Mots de passe** / secrets loggués dans un message ou une exception
  - **Payloads** bruts (body de requête/réponse) attachés en attribut ou en event
  - **Headers** HTTP sensibles (`Cookie`, `Set-Cookie`, `Authorization`, `X-Api-Key`)
  - URLs avec token/PII en **query string** (`http.url` = `?token=…&email=…`)
- **RGPD & PII** : ce qui est **interdit** (email, nom, téléphone, IP dans certains cas), notions de donnée personnelle, minimisation, rétention, pseudonymisation vs anonymisation
- **Conventions sémantiques & sécurité** : attributs sensibles connus, ne jamais surcharger un attribut standard avec de la PII
- **Stratégies de masquage — défense en profondeur** :
  1. **Masquage applicatif** (à la source, le plus sûr) : ne jamais émettre la donnée
  2. **Masquage SDK** : **SpanProcessor** (supprimer/hacher des attributs à l'`onEnd`), **LogRecordProcessor** (redaction du message/attributs), **Sampler** (drop conditionnel)
  3. **Masquage collecteur** (filet de sécurité central) : processors **Filter** / **Transform (OTTL)** / **Redaction**, `delete_key` / `hash` sur les attributs sensibles
- **Techniques** : suppression vs hachage vs troncature · **allowlist plutôt que denylist** · tests de non-régression anti-fuite · revue des attributs custom

### 🧪 Lab 8 — Masquage & anti-fuite *(45 min)*
**But** : détecter une fuite, puis la neutraliser à deux niveaux (appli/SDK **et** collecteur).
- **Provoquer la fuite** : ajouter volontairement un attribut sensible dans le micro-service (header `Authorization` / JWT, `user.email`, un `password`), générer une requête, **constater** la fuite dans Jaeger et OpenSearch
- **Masquer côté SDK** : implémenter un **SpanProcessor** qui supprime/hache l'attribut sensible + un **LogRecordProcessor** qui redact le message de log
- **Masquer côté collecteur** : ajouter un processor **redaction** / **transform (OTTL)** (`delete_key`, `hash`) sur `Authorization` et `email` — le filet de sécurité qui protège même les services non corrigés
- **Vérifier** : la donnée n'apparaît plus dans aucun backend
- **Bonus** : politique de **sampling** qui drop/conserve selon un attribut (réutilise le tail sampling du Lab 7)
- **Livrable** : preuve **avant / après** qu'un JWT et un email n'apparaissent plus dans Jaeger/OpenSearch, avec masquage appliqué à **2 niveaux** (SDK + collecteur).

---

## Chapitre 9 — Framework Spring *(slides, facultatif, en démo)*

- Appender Logback dans l'écosystème Spring
- Micrometer & OTLP
- Micrometer Tracing & OTLP
- Comparatif **Micrometer vs OpenTelemetry** (cf. [blog ITNext](https://itnext.io/distributed-tracing-with-spring-boot-3-micrometer-vs-opentelemetry-b3593546f61b))
> Chapitre **facultatif** : à traiter en démo pendant la conclusion si le groupe a de l'avance, ou à survoler si J2 déborde.

## Chapitre 10 — Conclusion *(slides, 15 min)*

- Synthèse : la chaîne complète SDK → collecteur → backend
- Bonnes pratiques (conventions sémantiques, coûts, cardinalité, sampling, **masquage PII / RGPD**)
- Aller plus loin (opérateur K8s, eBPF/OBI, profiles)
- Ressources (doc, livre *Learning OpenTelemetry*, démo, [Micrometer vs OTel](https://itnext.io/distributed-tracing-with-spring-boot-3-micrometer-vs-opentelemetry-b3593546f61b))

---

## Récapitulatif des 8 exercices

| # | Titre | Chapitre | Durée | Livrable |
|---|-------|----------|-------|----------|
| 1 | Démarrage de la stack | Introduction | 40 | Trace de bout en bout dans Jaeger |
| 2 | Instrumentation micro-service Java | Zero-code | 50 | 2 traces (agent + starter) |
| 3 | Configuration du collecteur | Collecteur | 55 | Métriques système + produit collectées |
| 4 | Dashboard unifié | Grafana | 50 | Dashboard 3-signaux exporté + alerte p95 déclenchée |
| 4.1 | Exemplars (lecture) | Grafana | 15 | — |
| 5 | Logs structurées | Logs | 45 | Log corrélé à sa trace |
| 6 | Métriques | Métriques | 60 | Graphe latence + compteur métier |
| 7 | Traces & sampling | Traces | 65 | Trace multi-services + tail sampling |
| 8 | Masquage & anti-fuite | Sécurité & conformité | 45 | JWT + email masqués (SDK + collecteur) |

> ⏱️ **D'où viennent ces durées.** Le volume de lecture de chaque lab a été mesuré
> (mots de prose + lignes de code), converti à 170 mots/min, puis complété par les temps
> machine relevés sur le serveur de formation (`up.sh` ≈ 3 min, un `deploy.sh` ≈ 45 s,
> un `helm upgrade` ≈ 2 min) et par les attentes incompressibles d'observabilité
> (cycle d'export 60 s, `for: 1m` d'une règle d'alerte, fenêtre `rate(...[2m])`).
>
> Les deux corrections principales par rapport à la version précédente : le **Lab 4**
> passe de 30 à 50 min — 21 min de lecture seule, et le déclenchement de l'alerte a un
> temps de propagation qu'on ne peut pas comprimer — et le **Lab 7** passe de 55 à
> 65 min, à cause de l'écriture du fichier de values `tail_sampling`. À l'inverse, les
> **Labs 1, 2 et 5** avaient une marge inutilisée.

---

## Checklist de préparation formateur

- [ ] Stack démo qui redémarre proprement (script `up.sh` / `down.sh` testés)
- [ ] Script `deploy.sh <service>` validé de bout en bout
- [ ] Micro-service Spring Boot custom prêt (API REST + accès PostgreSQL)
- [ ] Repo Git participant structuré (un dossier par lab + corrigés)
- [ ] Chaque lab testé sur une machine « vierge » (temps réel chronométré)
- [ ] Dashboards Grafana de secours pré-importés (si un lab échoue, on montre le résultat attendu)
- [ ] Config collecteur de référence par lab (versions « avant » / « après »)
- [ ] Plan B réseau : NodePort documenté si le port-forward pose problème en salle
- [ ] **Lab 8** : attributs sensibles « piégés » prêts à injecter (JWT/`Authorization`, `user.email`, `password`) + config collecteur **redaction/transform (OTTL)** de référence
- [ ] **Lab 8** : SpanProcessor / LogRecordProcessor de masquage écrits et testés (versions « avant » = fuite visible / « après » = masqué)
- [ ] Requêtes de vérification anti-fuite prêtes dans Jaeger et OpenSearch (recherche du token/email « avant » vs « après »)
