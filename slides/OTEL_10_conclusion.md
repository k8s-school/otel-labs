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

## Et chez vous, par où commencer ?

1. **Un service pilote**, pas le parc — celui dont on parle en réunion d'incident.
   L'agent, une variable d'environnement, zéro ligne de code (Lab 2)
2. **Un collecteur**, tenu par l'équipe plateforme : c'est lui qui porte les
   secrets des backends et les règles communes. Les applis n'en connaissent qu'un (Lab 3)
3. **Le backend que vous avez déjà.** OTLP se branche sur la plupart des solutions
   du marché — inutile d'attendre d'avoir tranché pour commencer
4. **Un dashboard et une alerte** sur ce service : c'est ce qui prouve la valeur
   à ceux qui financent la suite (Lab 4)
5. **Puis élargir** : les autres services d'abord, l'instrumentation manuelle
   seulement là où le métier le demande (Labs 6, 7)

- ⚠️ Deux décisions à prendre **avant** de généraliser : qui exploite le collecteur,
  et quelles données on refuse d'émettre (Lab 8)

---

## Aller plus loin

- **[Opérateur Kubernetes OpenTelemetry](https://opentelemetry.io/docs/platforms/kubernetes/operator/)** : injection automatique des agents
  ([`inject-java: "true"`](https://opentelemetry.io/docs/platforms/kubernetes/operator/automatic/)), gestion des collecteurs
- **[eBPF / OBI](https://github.com/open-telemetry/opentelemetry-ebpf-instrumentation)** (OpenTelemetry eBPF Instrumentation) : instrumentation noyau,
  zéro agent dans le process
- **[Profiles](https://opentelemetry.io/docs/specs/otel/profiles/)** : le 4ᵉ signal (profiling continu), en cours de standardisation
- Head → tail sampling à l'échelle : exporter [`loadbalancing`](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/loadbalancingexporter), mode gateway

---

## Ressources

- Documentation : <https://opentelemetry.io/docs/>
- La démo utilisée en formation : <https://opentelemetry.io/docs/demo/>
- Conventions sémantiques : <https://opentelemetry.io/docs/specs/semconv/>
- Livre : *Learning OpenTelemetry* (Young & Parker, O'Reilly)
- Micrometer vs OTel : [Tracing (Spring Boot)](https://docs.spring.io/spring-boot/reference/actuator/tracing.html) et [starter OTel](https://opentelemetry.io/docs/zero-code/java/spring-boot-starter/)
- Les labs de cette formation : <https://k8s-school.fr/labs/otel/>

---

# Merci !

## Questionnaire final & bilan

<img src="images/logo.svg" alt="K8s School Logo" width="50%">
