---
marp: true
theme: custom-theme
paginate: true
backgroundColor: #ffffff
---

# Formation OpenTelemetry

## Chapitre 10 — Conclusion

<img src="images/logo.svg" alt="K8s School Logo" width="50%">

---

## La chaîne complète — ce que vous avez construit

- `review-service` invisible → observable de bout en bout :
  - **traces** : agent zero-code, spans manuels, propagation multi-services (Labs 2, 7)
  - **métriques** : système, produit, métier, dérivées des spans (Labs 3, 6)
  - **logs** : structurés, corrélés aux traces (Lab 5)
  - **visualisation** : dashboard unifié + alerte (Lab 4)
  - **conformité** : PII masquées aux 3 niveaux (Lab 8)
- Le tout **sans modifier le backend** : OTLP + collecteur = découplage

---

## Bonnes pratiques — l'essentiel

- **Conventions sémantiques** : les respecter, ne jamais y mettre de PII
- **Cardinalité** : les identifiants dans les traces, pas dans les métriques
- **Sampling** : head simple par défaut, tail pour garder erreurs et lenteurs
- **Coûts** : filtrer au collecteur (healthchecks, endpoints bruyants) avant de payer le stockage
- **Sécurité** : masquage au collecteur versionné + tests anti-fuite en CI
- **Zero-code d'abord**, manuel là où le métier l'exige

---

## Aller plus loin

- **Opérateur Kubernetes OpenTelemetry** : injection automatique des agents
  (`instrumentation.opentelemetry.io/inject-java: "true"`), gestion des collecteurs
- **eBPF / OBI (OpenTelemetry eBPF Instrumentation)** : instrumentation noyau,
  zéro agent dans le process
- **Profiles** : le 4ᵉ signal (profiling continu), en cours de standardisation
- Head → tail sampling à l'échelle : exporter `loadbalancing`, mode gateway

---

## Ressources

- Documentation : <https://opentelemetry.io/docs/>
- La démo utilisée en formation : <https://opentelemetry.io/docs/demo/>
- Conventions sémantiques : <https://opentelemetry.io/docs/specs/semconv/>
- Livre : *Learning OpenTelemetry* (Young & Parker, O'Reilly)
- Micrometer vs OTel : [article ITNext](https://itnext.io/distributed-tracing-with-spring-boot-3-micrometer-vs-opentelemetry-b3593546f61b)
- Les labs de cette formation : <https://k8s-school.fr/otel/>

---

# Merci !

## Questionnaire final & bilan

<img src="images/logo.svg" alt="K8s School Logo" width="50%">
