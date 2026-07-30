#!/bin/bash

# Lab 4 solution: import the reference 3-signals dashboard into Grafana
# and check the datasources are wired.
# Assumes labs 1-3 are done (demo + review-service + collector config).

set -euxo pipefail

DIR=$(cd "$(dirname "$0")"; pwd -P)
NS="otel-demo"

. "$DIR/../../scripts/env.sh"

kubectl port-forward -n "$NS" --address "$PF_ADDR" svc/frontend-proxy "$UI_PORT":8080 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
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

echo "Lab 4 OK: unified dashboard imported in Grafana"
