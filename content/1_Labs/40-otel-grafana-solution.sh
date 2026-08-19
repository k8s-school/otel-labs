#!/bin/bash

# Lab 4 solution: import the reference 3-signals dashboard into Grafana
# and check the datasources are wired. Also checks what lab 4.1 reads: the
# exemplars dashboard shipped by the demo, and the metric it plots.
# Assumes labs 1-3 are done (demo + review-service + collector config).

set -euxo pipefail

DIR=$(cd "$(dirname "$0")"; pwd -P)
NS="otel-demo"

. "$DIR/../../scripts/env.sh"

kubectl port-forward -n "$NS" --address "$PF_ADDR" svc/frontend-proxy "$UI_PORT":8080 &
PF_PID=$!
kubectl port-forward -n "$NS" --address "$PF_ADDR" svc/prometheus "$PROM_PORT":9090 &
PROM_PF_PID=$!
trap 'kill $PF_PID $PROM_PF_PID 2>/dev/null || true' EXIT
sleep 3

GRAFANA="http://$PF_HOST:$UI_PORT/grafana"

# Grafana is up (anonymous access with Admin role in the demo).
# Capture before matching: 'curl | grep -q' lets grep close the pipe on the first
# match, curl dies of EPIPE and 'set -o pipefail' fails the script at random.
HEALTH=$(curl -sSf "$GRAFANA/api/health")
grep -q "ok" <<< "$HEALTH"

# The three datasources of the three signals are provisioned
DS=$(curl -sSf "$GRAFANA/api/datasources")
grep -q "webstore-metrics" <<< "$DS"   # Prometheus
grep -q "webstore-traces" <<< "$DS"    # Jaeger
grep -q "webstore-logs" <<< "$DS"      # OpenSearch

# Import the reference dashboard (the lab deliverable)
PAYLOAD=$(printf '{"overwrite": true, "dashboard": %s}' "$(cat "$DIR/40-otel-grafana-dashboard.json")")
IMPORTED=$(curl -sSf -X POST "$GRAFANA/api/dashboards/db" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD")
grep -q '"status":"success"' <<< "$IMPORTED"

# The dashboard is retrievable by uid
DASHBOARD=$(curl -sSf "$GRAFANA/api/dashboards/uid/otel-training-service")
grep -q "Vue service" <<< "$DASHBOARD"

# The alert rule of step 7. It does NOT live in the dashboard JSON: unified
# alerting took rules out of dashboards (legacy alerting is gone since Grafana
# 11), so a rule needs its own folder and evaluation group.
# 409 on the folder just means a previous run created it.
curl -sS -X POST "$GRAFANA/api/folders" -H "Content-Type: application/json" \
    -d '{"uid":"otel-training","title":"Formation OTel"}' > /dev/null || true
# X-Disable-Provenance: without it Grafana marks the rule as provisioned and
# the UI refuses to edit it - the participant must be able to move the threshold.
curl -sS -X DELETE "$GRAFANA/api/v1/provisioning/alert-rules/otel-training-p95" \
    -H "X-Disable-Provenance: true" > /dev/null 2>&1 || true
RULE=$(curl -sSf -X POST "$GRAFANA/api/v1/provisioning/alert-rules" \
    -H "Content-Type: application/json" -H "X-Disable-Provenance: true" \
    -d @"$DIR/40-otel-grafana-alert.json")
grep -q '"uid":"otel-training-p95"' <<< "$RULE"

# The panel threshold and the rule threshold are two files that must agree:
# the participant reads one and the alert uses the other.
python3 - "$DIR/40-otel-grafana-alert.json" "$DIR/40-otel-grafana-dashboard.json" << 'PYEOF'
import json, sys
rule, dash = (json.load(open(p)) for p in sys.argv[1:3])
in_rule = rule["data"][1]["model"]["conditions"][0]["evaluator"]["params"][0]
panel = next(p for p in dash["panels"] if p["id"] == 2)
in_panel = next(s["value"] for s in panel["fieldConfig"]["defaults"]["thresholds"]["steps"]
                if s["color"] == "red")
if in_rule != in_panel:
    sys.exit("ERROR: alert rule fires at %s ms but the panel draws its line at %s ms" % (in_rule, in_panel))
print("Alert threshold consistent: %s ms in both the rule and the panel" % in_rule)
PYEOF

# Grafana evaluates it without error (a bad expression would show up here as
# health=error). Not asserted: that it fires - that needs 3 minutes of load.
sleep 5
RULES=$(curl -sSf "$GRAFANA/api/prometheus/grafana/api/v1/rules")
python3 -c '
import json, sys
groups = json.load(sys.stdin)["data"]["groups"]
rules = [r for g in groups for r in g["rules"] if r.get("name") == "Latence p95 du review-service"]
if not rules:
    sys.exit("ERROR: alert rule not evaluated by Grafana")
health = rules[0].get("health")
if health not in ("ok", "nodata"):
    sys.exit("ERROR: alert rule health=%s (%s)" % (health, rules[0].get("lastError")))
print("Alert rule in place, health=%s, state=%s" % (health, rules[0].get("state")))
' <<< "$RULES"

# --- lab 4.1 reads a dashboard shipped by the demo: check it is in place ---

# The dashboard itself (uid is stable across clusters, it comes from the chart)
EXEMPLARS=$(curl -sSf "$GRAFANA/api/dashboards/uid/ce6sd46kfkglca")
grep -q "Cart Service Exemplars" <<< "$EXEMPLARS"

# The metric its panels plot. This is the real guard: the demo renamed
# app_cart_* to demo_cart_* after appVersion 2.2.0 (the one chart 0.40.9
# pins), so the day the chart is unpinned lab 4.1 would silently go stale.
# Wait for it: the cart service only publishes once the load generator has hit it.
found=false
for i in $(seq 1 24); do
    NAMES=$(curl -sSf "http://$PF_HOST:$PROM_PORT/api/v1/label/__name__/values" || true)
    if grep -q '"app_cart_get_cart_latency_seconds_bucket"' <<< "$NAMES"; then
        found=true
        break
    fi
    sleep 5
done
if [ "$found" != true ]; then
    echo "ERROR: app_cart_get_cart_latency_seconds_bucket not found in Prometheus"
    echo "       lab 4.1 (exemplars) documents that metric name - check the chart version"
    exit 1
fi

# Exemplars themselves are NOT a hard check: they only live for one export
# cycle and depend on traffic, which would make this flaky in CI.
EX=$(curl -sSf -G "http://$PF_HOST:$PROM_PORT/api/v1/query_exemplars" \
    --data-urlencode 'query=app_cart_get_cart_latency_seconds_bucket' \
    --data-urlencode "start=$(date -d '-1 hour' +%s)" \
    --data-urlencode "end=$(date +%s)" || true)
if grep -q '"traceID"' <<< "$EX" || grep -q '"trace_id"' <<< "$EX"; then
    echo "Exemplars present on app_cart_get_cart_latency_seconds_bucket"
else
    echo "WARNING: no exemplar returned yet - lab 4.1 needs traffic on the cart service"
fi

echo "Lab 4 OK: dashboard + alert rule in Grafana, lab 4.1 dashboard in place"
