---
marp: true
theme: custom-theme
paginate: true
backgroundColor: #ffffff
---

# Formation OpenTelemetry

## Chapitre 8 — Sécurité & conformité

<img src="images/logo.svg" alt="K8s School Logo" width="50%">

---

## La télémétrie est un canal de fuite

- Le backend d'observabilité est rarement protégé comme la base de prod
  - accès larges (toute l'équipe, parfois l'entreprise), rétention longue, sauvegardes
- Fuites **fréquentes** (vues au lab, dans un code réaliste) :
  - header **`Authorization`** / token **JWT** copiés attribut de span
  - **mot de passe / secret** dans un message de log ou une stack trace
  - **payload** complet (body de requête) en attribut « pour debug »
  - header **`Cookie`** / `X-Api-Key`
  - URL avec token ou PII en query string (`url.full = ...?token=...&email=...`)

---

## RGPD : ce qui est interdit dans la télémétrie

- **PII** = donnée personnelle : email, nom, téléphone, adresse (IP parfois !)
- PII dans les traces/logs ⇒ mêmes obligations que la base de prod :
  - droit à l'effacement... dans un backend append-only 😱
  - minimisation, limitation de rétention, registre des traitements
- Principes :
  - **minimisation** : ne pas émettre ce dont on n'a pas besoin
  - **pseudonymisation** (hachage → corrélation possible) vs
    **anonymisation** (suppression)
  - conventions sémantiques : ne jamais surcharger un attribut standard avec de la PII

---

## Défense en profondeur : 3 niveaux (1/2)

1. **Applicatif** (le seul vrai correctif) : ne pas émettre — pas de `setAttribute("user.email", ...)`, pas de PII dans les logs
2. **SDK** : possible, mais **lourd** —
   1. objets SDK sur mesure propres à chaque langage
   2. code à recompiler/redéployer
   3. une logique de nettoyage à maintenir
   4. A n'implémenter que si la donnée ne doit **jamais quitter la mémoire** du processus ([exemple d'extension](https://github.com/open-telemetry/opentelemetry-java-instrumentation/tree/main/examples/extension))

---

## Défense en profondeur : 3 niveaux (2/2)

3. **Collecteur** — le choix par défaut en production :
   - **zéro code** : les applications émettent normalement
   - un **YAML déclaratif et centralisé** ([`attributes`](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/attributesprocessor), OTTL) : une clé sensible
     apparaît → on modifie le collecteur, pas les microservices
   - il protège **tous** les services, même ceux qu'on ne contrôle pas

⚠️ Rien de tout cela n'efface après coup : aux niveaux 1 et 2 la donnée n'a pas quitté le processus, au niveau 3 elle n'a pas quitté le cluster. Après le backend, il est trop tard.

---

## Masquage au collecteur : OTTL

```yaml
processors:                    # deux INSTANCES du même processor : transform
  transform/pii-spans:
    trace_statements:
      - context: span
        statements:
          - delete_key(span.attributes, "user.email")
          - delete_key(span.attributes, "http.request.header.authorization")
  transform/pii-logs:
    log_statements:
      - context: log
        statements:
          - replace_pattern(log.body, "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+", "***@***")
service:
  pipelines:                   # sans ce branchement, rien ne s'applique (chapitre 3)
    traces: { processors: [..., transform/pii-spans, batch] }
    logs:   { processors: [..., transform/pii-logs,  batch] }
```

- `transform` est **un** processor (celui du langage OTTL) ; le suffixe après `/` est un **nom libre**, qui distingue deux instances : spans/logs

---

## Masquage au collecteur : Variantes

- [`replace_pattern(..., hash)`](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/pkg/ottl/ottlfuncs/README.md#replace_pattern) pour pseudonymiser, ou le processor
- [**`redaction`**](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/redactionprocessor) — **allowlist** : seuls les attributs autorisés passent, plus sûr

---

## Réflexes opérationnels

- **Allowlist plutôt que denylist** : on n'oublie pas ce qu'on n'a pas listé
- Règles de masquage **au collecteur, versionnées** (Git) — appliquées à tout le parc
- **Tests anti-fuite** : injecter un marqueur (email, faux token) en CI et
  vérifier qu'il n'atteint aucun backend *(c'est ce que fait la correction du lab !)*
- Revue de code des `setAttribute` custom et des messages de log
- Le masquage aval est un **filet** : la faute reste dans le code — la corriger

---

## 🧪 LAB 8 — Masquer les données sensibles

- **Constater** : JWT + email dans Jaeger, email dans OpenSearch
- **Corriger le code** : les 3 lignes fautives de `ReviewController` — le seul vrai
  correctif... mais il ne couvre que le code que vous écrivez
- **Masquer au collecteur** : OTTL `delete_key` + `replace_pattern`
  → plus rien ne fuit, **pour tous les services**, y compris ceux restés fautifs

➡ [Lab 8 — Sécurité & conformité](https://k8s-school.fr/labs/otel/fr/1_labs/80-otel-security/index.html)

*Livrable : la preuve avant/après — la même requête, le code fautif inchangé, et plus rien ne fuit.*
