#!/bin/bash

# Lab 1 solution: start the observability stack and check it end to end.
# Assumes a kind cluster is reachable (create one with scripts/up.sh -c).

set -euxo pipefail

DIR=$(cd "$(dirname "$0")"; pwd -P)

# Install the OpenTelemetry demo (idempotent)
"$DIR/../../scripts/up.sh"

NS="otel-demo"

# All pods must be running and ready
kubectl wait --for=condition=Ready pods --all -n "$NS" --timeout=600s

# Access the UIs through the frontend proxy
kubectl port-forward -n "$NS" svc/frontend-proxy 8080:8080 &
PF_PID=$!
trap 'kill $PF_PID' EXIT
sleep 3

# The shop frontend answers
curl -sSf -o /dev/null http://localhost:8080/

# Grafana answers
curl -sSf -o /dev/null http://localhost:8080/grafana/

# The load generator produced traces: Jaeger must know the checkout service
# (give the pipeline up to 2 minutes to see the first traces)
for i in $(seq 1 24); do
    if curl -sSf http://localhost:8080/jaeger/ui/api/services | grep -q "checkout"; then
        break
    fi
    sleep 5
done
curl -sSf http://localhost:8080/jaeger/ui/api/services | grep -q "checkout"

# Deliverable check: at least one end-to-end checkout trace exists
curl -sSf "http://localhost:8080/jaeger/ui/api/traces?service=checkout&limit=1" | grep -q "traceID"

echo "Lab 1 OK: stack is up, traces are flowing into Jaeger"
