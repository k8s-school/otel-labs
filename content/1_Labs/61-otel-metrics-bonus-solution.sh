#!/bin/bash

# Lab 6 bonus solution: count failed requests rather than spans in error.
# Assumes labs 1-6 are done (instrumented review-service, count connector on).
#
# The bonus page adds a second metric to the same connector, restricted to
# server spans: one point per failed request, where app.spans.errors counts
# every span the failure leaves behind. Both must be there, and the request
# one must stay below the span one.
#
# EXTRA_VALUES can carry additional values files (e.g. CI).

set -euxo pipefail

DIR=$(cd "$(dirname "$0")"; pwd -P)
NS="otel-demo"

. "$DIR/../../scripts/env.sh"

APP_PF_PID=""
PROM_PF_PID=""
cleanup() {
    [ -n "$APP_PF_PID" ] && kill "$APP_PF_PID" 2>/dev/null || true
    [ -n "$PROM_PF_PID" ] && kill "$PROM_PF_PID" 2>/dev/null || true
}
trap cleanup EXIT

start_app_port_forward() {
    [ -n "$APP_PF_PID" ] && kill "$APP_PF_PID" 2>/dev/null || true
    kubectl port-forward -n "$NS" --address "$PF_ADDR" svc/review-service "$APP_PORT":8080 &
    APP_PF_PID=$!
    for i in $(seq 1 12); do
        curl -sSf -o /dev/null "http://$PF_HOST:$APP_PORT/api/reviews" && return 0
        sleep 5
    done
    echo "ERROR: review-service still unreachable through the port-forward"
    return 1
}

fail_three_requests() {
    for i in $(seq 1 3); do
        curl -s -o /dev/null -X POST "http://$PF_HOST:$APP_PORT/api/reviews" \
            -H "Content-Type: application/json" \
            -d '{"productId": "DOESNOTEXIST", "rating": 5, "comment": "?", "userEmail": "x@example.com", "userName": "X"}' \
            || true
    done
}

# The bonus values stack on top of the lab 6 ones: helm merges maps, so the
# new metric is added to app.spans.errors rather than replacing it.
helm upgrade "$RELEASE" "$CHART" \
    --version "$CHART_VERSION" \
    --namespace "$NS" \
    -f "$DIR/../../manifests/values-training.yaml" \
    ${EXTRA_VALUES:-} \
    -f "$DIR/30-otel-collector-values.yaml" \
    -f "$DIR/60-otel-metrics-values.yaml" \
    -f "$DIR/61-otel-metrics-values.yaml" \
    --timeout 10m
kubectl rollout status daemonset/otel-collector-agent -n "$NS" --timeout=300s

start_app_port_forward
kubectl port-forward -n "$NS" --address "$PF_ADDR" svc/prometheus "$PROM_PORT":9090 &
PROM_PF_PID=$!
sleep 3

fail_three_requests

# Both metrics must exist, and the request one must count fewer points than
# the span one: that is the whole point of the bonus.
found=""
for i in $(seq 1 24); do
    RESULT=$(curl -sSf -G "http://$PF_HOST:$PROM_PORT/api/v1/query" \
        --data-urlencode 'query=sum(app_requests_errors_total{service_name="review-service"}) or vector(0)' || true)
    REQUESTS=$(python3 -c '
import json, sys
r = json.load(sys.stdin).get("data", {}).get("result") or []
print(r[0]["value"][1] if r else "")
' <<< "$RESULT" || true)
    SPAN_RESULT=$(curl -sSf -G "http://$PF_HOST:$PROM_PORT/api/v1/query" \
        --data-urlencode 'query=sum(app_spans_errors_total{service_name="review-service"}) or vector(0)' || true)
    SPANS=$(python3 -c '
import json, sys
r = json.load(sys.stdin).get("data", {}).get("result") or []
print(r[0]["value"][1] if r else "")
' <<< "$SPAN_RESULT" || true)
    if [ -n "$REQUESTS" ] && [ -n "$SPANS" ] \
        && python3 -c "import sys; sys.exit(0 if float('$REQUESTS') >= 3 and float('$SPANS') > float('$REQUESTS') else 1)"; then
        found=yes
        break
    fi
    fail_three_requests || true
    sleep 5
done
if [ "$found" != "yes" ]; then
    echo "ERROR: expected app_requests_errors_total >= 3 and below app_spans_errors_total"
    echo "       got requests=$REQUESTS spans=$SPANS"
    exit 1
fi

echo "Lab 6 bonus OK: $REQUESTS failed requests counted, against $SPANS spans in error"
