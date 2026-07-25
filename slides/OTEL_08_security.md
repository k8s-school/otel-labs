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
  - header **`Authorization`** / token **JWT** copié en attribut de span → rejouable !
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

## Défense en profondeur : 3 niveaux

1. **Applicatif** (le seul vrai correctif) :
   ne pas émettre — pas de `setAttribute("user.email", ...)`, pas de PII dans les logs
2. **SDK** (dans le processus) :
   - **`Sampler`** : ne pas créer certaines traces
   - **`SpanProcessor` / `LogRecordProcessor`** : filtrer, enrichir, masquer les *attributs*
   - le *body* d'un log se réécrit via un **wrapper d'exporter** (API stable)
3. **Collecteur** (le filet de sécurité central) :
   protège **tous** les services, même ceux qu'on ne contrôle pas

---

## Masquage au collecteur : OTTL

```yaml
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
```

- Variantes : `replace_pattern(..., hash)` (pseudonymiser), processor **`redaction`**
  (approche **allowlist** : seuls les attributs autorisés passent — plus sûr)

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
- **Masquer au SDK** : wrapper d'exporter de logs (`MASK_PII=true`)
  → le log est propre... le span fuit toujours !
- **Masquer au collecteur** : OTTL `delete_key` + `replace_pattern`
  → plus rien ne fuit, pour tous les services
- **Corriger le code** : supprimer les 3 lignes fautives

➡ [Lab 8 — Sécurité & conformité](https://k8s-school.fr/labs/otel/fr/1_labs/80-otel-security/index.html)

*Livrable : la preuve avant/après.*
