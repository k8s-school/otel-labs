#!/bin/bash

# Lab 4 solution: import the reference 3-signals dashboard into Grafana
# and check the datasources are wired.
# Assumes labs 1-3 are done (demo + review-service + collector config).

set -euxo pipefail

DIR=$(cd "$(dirname "$0")"; pwd -P)
NS="otel-demo"

kubectl port-forward -n "$NS" svc/frontend-proxy 8080:8080 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
sleep 3

GRAFANA="http://localhost:8080/grafana"

# Grafana is up (anonymous access with Admin role in the demo)
curl -sSf "$GRAFANA/api/health" | grep -q "ok"

# The three datasources of the three signals are provisioned
DS=$(curl -sSf "$GRAFANA/api/datasources")
echo "$DS" | grep -q "webstore-metrics"   # Prometheus
echo "$DS" | grep -q "webstore-traces"    # Jaeger
echo "$DS" | grep -q "webstore-logs"      # OpenSearch

# Import the reference dashboard (the lab deliverable)
PAYLOAD=$(printf '{"overwrite": true, "dashboard": %s}' "$(cat "$DIR/40-otel-grafana-dashboard.json")")
curl -sSf -X POST "$GRAFANA/api/dashboards/db" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" | grep -q '"status":"success"'

# The dashboard is retrievable by uid
curl -sSf "$GRAFANA/api/dashboards/uid/otel-training-service" \
    | grep -q "Vue service"

echo "Lab 4 OK: unified dashboard imported in Grafana"
