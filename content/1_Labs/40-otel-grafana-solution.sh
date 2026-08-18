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

echo "Lab 4 OK: unified dashboard imported in Grafana, lab 4.1 dashboard in place"
