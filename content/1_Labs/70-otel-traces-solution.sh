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
PROM_PF_PID=""
cleanup() {
    [ -n "$APP_PF_PID" ] && kill "$APP_PF_PID" 2>/dev/null || true
    [ -n "$PROXY_PF_PID" ] && kill "$PROXY_PF_PID" 2>/dev/null || true
    [ -n "$PROM_PF_PID" ] && kill "$PROM_PF_PID" 2>/dev/null || true
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

# --- Part 1b: the caller imposes the trace context (lab step 4) ---
# A traceparent sent by hand must be adopted as-is - same trace id, and the
# server span's parent is the span id we made up, even though no such span
# exists. Checked here, before tail sampling starts dropping traces.
TRACE_ID=$(printf 'ba66a9e%025x' "$(date +%s)")
curl -sSf -X POST http://$PF_HOST:$APP_PORT/api/reviews \
    -H "Content-Type: application/json" \
    -H "traceparent: 00-$TRACE_ID-00f067aa0ba902b7-01" \
    -d '{"productId": "OLJCESPC7Z", "rating": 5, "comment": "w3c", "userEmail": "a@b.c", "userName": "A"}' \
    > /dev/null

found=""
for i in $(seq 1 24); do
    TRACE=$(curl -sSf "http://$PF_HOST:$UI_PORT/jaeger/ui/api/traces/$TRACE_ID" || true)
    if grep -q '"spanID":"00f067aa0ba902b7"' <<< "$TRACE"; then
        found=yes
        break
    fi
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

# The processor keeps its own counters, one vote per policy and per trace.
# The lab reads them to prove the policy works without counting lines on
# screen; check the three policies are there and actually voting.
kubectl port-forward -n "$NS" --address "$PF_ADDR" svc/prometheus "$PROM_PORT":9090 &
PROM_PF_PID=$!
sleep 3

found=""
for i in $(seq 1 24); do
    COUNTERS=$(curl -sSf -G "http://$PF_HOST:$PROM_PORT/api/v1/query" \
        --data-urlencode 'query=sum by (policy) (otelcol_processor_tail_sampling_count_traces_sampled_total)' || true)
    if grep -q '"keep-errors"' <<< "$COUNTERS" \
        && grep -q '"keep-slow"' <<< "$COUNTERS" \
        && grep -q '"sample-the-rest"' <<< "$COUNTERS"; then
        found=yes
        break
    fi
    sleep 5
done
[ "$found" = "yes" ]

echo "Lab 7 OK: multi-service trace with manual span, imposed W3C context honoured,"
echo "          error traces survive tail sampling, processor counters exposed"
