#!/bin/bash

# Lab 7 solution: manual spans, cross-service propagation and tail sampling.
# Assumes labs 1-6 are done (instrumented review-service with Java agent).
#
# EXTRA_VALUES can carry additional values files (e.g. CI).

set -euxo pipefail

DIR=$(cd "$(dirname "$0")"; pwd -P)
NS="otel-demo"

. "$DIR/../../scripts/env.sh"

APP_PF_PID=""
PROXY_PF_PID=""
cleanup() {
    [ -n "$APP_PF_PID" ] && kill "$APP_PF_PID" 2>/dev/null || true
    [ -n "$PROXY_PF_PID" ] && kill "$PROXY_PF_PID" 2>/dev/null || true
}
trap cleanup EXIT

kubectl port-forward -n "$NS" --address "$PF_ADDR" svc/frontend-proxy "$UI_PORT":8080 &
PROXY_PF_PID=$!
kubectl port-forward -n "$NS" --address "$PF_ADDR" svc/review-service "$APP_PORT":8080 &
APP_PF_PID=$!
sleep 3

# --- Part 1: multi-service trace (review-service -> frontend) ---
curl -sSf -X POST http://$PF_HOST:$APP_PORT/api/reviews \
    -H "Content-Type: application/json" \
    -d '{"productId": "OLJCESPC7Z", "rating": 5, "comment": "Trace me!", "userEmail": "ada.lovelace@example.com", "userName": "Ada Lovelace"}' \
    > /dev/null

# A review-service trace must contain the manual span AND a frontend process
found=""
for i in $(seq 1 24); do
    TRACES=$(curl -sSf "http://$PF_HOST:$UI_PORT/jaeger/ui/api/traces?service=review-service&operation=POST%20%2Fapi%2Freviews&limit=20" || true)
    if grep -q "product-catalog.lookup" <<< "$TRACES" \
        && grep -q '"serviceName":"frontend"' <<< "$TRACES"; then
        found=yes
        break
    fi
    curl -sSf -X POST http://$PF_HOST:$APP_PORT/api/reviews \
        -H "Content-Type: application/json" \
        -d '{"productId": "OLJCESPC7Z", "rating": 4, "comment": "retry", "userEmail": "ada.lovelace@example.com", "userName": "Ada Lovelace"}' \
        > /dev/null || true
    sleep 5
done
[ "$found" = "yes" ]

# --- Part 2: tail sampling ---
helm upgrade "$RELEASE" "$CHART" \
    --version "$CHART_VERSION" \
    --namespace "$NS" \
    -f "$DIR/../../manifests/values-training.yaml" \
    ${EXTRA_VALUES:-} \
    -f "$DIR/30-otel-collector-values.yaml" \
    -f "$DIR/60-otel-metrics-values.yaml" \
    -f "$DIR/70-otel-traces-values.yaml" \
    --timeout 10m
kubectl rollout status daemonset/otel-collector-agent -n "$NS" --timeout=300s
sleep 5

# Error traces must survive the sampling policy (status_code policy)
curl -s -o /dev/null -X POST http://$PF_HOST:$APP_PORT/api/reviews \
    -H "Content-Type: application/json" \
    -d '{"productId": "DOESNOTEXIST", "rating": 5, "comment": "?", "userEmail": "x@example.com", "userName": "X"}' \
    || true

found=""
for i in $(seq 1 24); do
    # Capture before matching: 'curl | grep -q' lets grep close the pipe on the
    # first match, curl dies of EPIPE and pipefail fails the script.
    ERR_TRACES=$(curl -sSf "http://$PF_HOST:$UI_PORT/jaeger/ui/api/traces?service=review-service&tags=%7B%22error%22%3A%22true%22%7D&limit=10" || true)
    if grep -q "traceID" <<< "$ERR_TRACES"; then
        found=yes
        break
    fi
    curl -s -o /dev/null -X POST http://$PF_HOST:$APP_PORT/api/reviews \
        -H "Content-Type: application/json" \
        -d '{"productId": "DOESNOTEXIST", "rating": 5, "comment": "?", "userEmail": "x@example.com", "userName": "X"}' \
        || true
    sleep 5
done
[ "$found" = "yes" ]

echo "Lab 7 OK: multi-service trace with manual span, error traces survive tail sampling"
