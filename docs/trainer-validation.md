# Trainer guide: validating the training end to end

Two complementary validation layers exist. The **automated one** (CI and the
solution scripts) proves every command works and the data reaches each
backend. The **manual one** — described here — is what only a human can
check: what the UIs actually show, how clear the instructions are, and how
long each lab really takes.

## What the automation already covers

```bash
./content/1_Labs/10-otel-stack-solution.sh
./content/1_Labs/20-otel-zero-code-solution.sh
./content/1_Labs/30-otel-collector-solution.sh
./content/1_Labs/40-otel-grafana-solution.sh
./content/1_Labs/50-otel-logs-solution.sh
./content/1_Labs/60-otel-metrics-solution.sh
./content/1_Labs/70-otel-traces-solution.sh
./content/1_Labs/80-otel-security-solution.sh
```

Scripts are **sequential** (each one assumes the previous ones ran). They
verify through the APIs: traces in Jaeger, metrics in Prometheus, correlated
logs in OpenSearch, PII masked at both levels. The GitHub Actions workflow
replays the same sequence on a fresh kind cluster.

## Manual validation walkthrough

### 1. Start from a clean slate

```bash
./scripts/down.sh     # delete the kind cluster
./scripts/up.sh -c    # recreate it + install the demo (pinned chart 0.40.9)
```

Starting fresh also validates the exact "day 1 morning" path participants
will follow.

### 2. Serve the labs locally

```bash
hugo serve            # -> http://localhost:1313
```

### 3. Play each lab as a participant

Follow the labs in order from the website, **without looking at the
solutions first** — the collapsed "Réponse" blocks are the participant
experience, use them only when stuck.

Things the scripts cannot judge, watch for them explicitly:

- **UI experience**: the span hierarchy in Jaeger (lab 7), the log→trace
  click-through in Grafana (lab 5), the before/after of the PII masking
  (lab 8), zPages content (lab 3)
- **Wording**: are the instructions unambiguous for a DevOps discovering
  OpenTelemetry? Are the "Réponse" blocks at the right depth?
- **Manual steps**: build the Grafana dashboard by hand (lab 4 steps 2-6);
  the solution script imports the reference JSON, which validates nothing
  about the UI workflow
- **Failure modes**: try a wrong YAML indent in lab 3, a forgotten
  re-listed receiver — are the error messages recoverable in classroom
  conditions?

### 4. Time every lab

Fill this table while playing; the run-sheet in
`programme-otel-michelin.md` uses the theoretical durations and must be
recalibrated with real ones:

| Lab | Planned | Actual | Notes |
|-----|---------|--------|-------|
| 1 — Stack           | 45 min | | |
| 2 — Zero-code       | 70 min | | |
| 3 — Collector       | 60 min | | |
| 4 — Grafana         | 35 min | | |
| 5 — Logs            | 55 min | | |
| 6 — Metrics         | 70 min | | |
| 7 — Traces          | 55 min | | |
| 8 — Security        | 40 min | | |

### 5. Recover / reset between attempts

```bash
# Re-align the collector with a given lab state (values files stack):
helm upgrade otel-demo open-telemetry/opentelemetry-demo \
  --version 0.40.9 -n otel-demo \
  -f manifests/values-training.yaml \
  -f content/1_Labs/30-otel-collector-values.yaml   # + 60/70/80 as needed

# Redeploy review-service from scratch:
./scripts/deploy.sh

# Nuclear option: ./scripts/down.sh && ./scripts/up.sh -c  (~10 min)
```

## Known pitfalls (already hit during validation)

- **kind >= v0.27 required**: older CLIs fail with `failed to detect
  containerd snapshotter` when loading images (guard built into
  `deploy.sh`)
- **The collector DaemonSet is named `otel-collector-agent`** (the service
  is `otel-collector`)
- **The agent's Micrometer bridge is opt-in**:
  `OTEL_INSTRUMENTATION_MICROMETER_ENABLED=true` (lab 6) — without it the
  business metrics silently never show up
- **Tail sampling (lab 7) drops ~75% of successful traces afterwards**:
  when hunting for a specific trace in labs 7-8, re-send the request until
  one survives, or look for error traces (kept at 100%)
- `kubectl port-forward` binds a **single pod**: restart it after every
  rollout of review-service

## Reporting

Note every friction point (typo, unclear step, timing off, UI mismatch)
and feed it back — labs and run-sheet are regenerated from these findings.
