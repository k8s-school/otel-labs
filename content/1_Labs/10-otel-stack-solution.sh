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
kubectl port-forward -n "$NS" --address "$PF_ADDR" svc/frontend-proxy "$UI_PORT":8080 &
PF_PID=$!
trap 'kill $PF_PID' EXIT
sleep 3

# A UI can still answer 503 for a few seconds after its pod is Ready, while the
# frontend-proxy (Envoy) refreshes its upstream endpoints. Retry rather than
# fail on that race.
wait_for_url() {
    local url="$1"
    for i in $(seq 1 24); do
        if curl -sSf -o /dev/null "$url"; then
            return 0
        fi
        sleep 5
    done
    echo "ERROR: $url still unreachable after 2 minutes"
    return 1
}

# The shop frontend answers
wait_for_url http://$PF_HOST:$UI_PORT/

# Grafana answers
wait_for_url http://$PF_HOST:$UI_PORT/grafana/

# The load generator produced traces: Jaeger must know the checkout service
# (give the pipeline up to 2 minutes to see the first traces)
# Never pipe a command straight into 'grep -q': grep exits on the first match and
# closes the pipe, the producer dies of EPIPE, and 'set -o pipefail' turns that
# into a failure -- intermittently, depending on where the match falls in the
# stream. Capture first, match afterwards.
for i in $(seq 1 24); do
    SERVICES=$(curl -sSf "http://$PF_HOST:$UI_PORT/jaeger/ui/api/services" || true)
    if grep -q "checkout" <<< "$SERVICES"; then
        break
    fi
    sleep 5
done
grep -q "checkout" <<< "$SERVICES"

# Deliverable check: at least one end-to-end checkout trace exists
TRACES=$(curl -sSf "http://$PF_HOST:$UI_PORT/jaeger/ui/api/traces?service=checkout&limit=1")
grep -q "traceID" <<< "$TRACES"

echo "Lab 1 OK: stack is up, traces are flowing into Jaeger"
