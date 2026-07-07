#!/bin/bash

# Lab 1 solution: start the observability stack and check it end to end.
# Assumes a kind cluster is reachable (create one with scripts/up.sh -c).

set -euxo pipefail

DIR=$(cd "$(dirname "$0")"; pwd -P)

# Install the OpenTelemetry demo (idempotent). up.sh already waits for the
# demo pods to be ready, with retries.
"$DIR/../../scripts/up.sh"

NS="otel-demo"

. "$DIR/../../scripts/env.sh"

# Access the UIs through the frontend proxy
kubectl port-forward -n "$NS" svc/frontend-proxy "$UI_PORT":8080 &
PF_PID=$!
trap 'kill $PF_PID' EXIT
sleep 3

# The shop frontend answers
curl -sSf -o /dev/null http://localhost:$UI_PORT/

# Grafana answers
curl -sSf -o /dev/null http://localhost:$UI_PORT/grafana/

# The load generator produced traces: Jaeger must know the checkout service
# (give the pipeline up to 2 minutes to see the first traces)
for i in $(seq 1 24); do
    if curl -sSf http://localhost:$UI_PORT/jaeger/ui/api/services | grep -q "checkout"; then
        break
    fi
    sleep 5
done
curl -sSf http://localhost:$UI_PORT/jaeger/ui/api/services | grep -q "checkout"

# Deliverable check: at least one end-to-end checkout trace exists
curl -sSf "http://localhost:$UI_PORT/jaeger/ui/api/traces?service=checkout&limit=1" | grep -q "traceID"

echo "Lab 1 OK: stack is up, traces are flowing into Jaeger"
