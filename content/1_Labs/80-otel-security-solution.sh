#!/bin/bash

# Lab 8 solution: PII leak, then masking at the SDK level (logs) and at the
# collector level (spans + logs).
# Assumes labs 1-7 are done.
#
# EXTRA_VALUES can carry additional values files (e.g. CI).

set -euxo pipefail

DIR=$(cd "$(dirname "$0")"; pwd -P)
NS="otel-demo"

. "$DIR/../../scripts/env.sh"

APP_PF_PID=""
PROXY_PF_PID=""
OS_PF_PID=""
cleanup() {
    [ -n "$APP_PF_PID" ] && kill "$APP_PF_PID" 2>/dev/null || true
    [ -n "$PROXY_PF_PID" ] && kill "$PROXY_PF_PID" 2>/dev/null || true
    [ -n "$OS_PF_PID" ] && kill "$OS_PF_PID" 2>/dev/null || true
}
trap cleanup EXIT

kubectl port-forward -n "$NS" --address "$PF_ADDR" svc/frontend-proxy "$UI_PORT":8080 &
PROXY_PF_PID=$!
kubectl port-forward -n "$NS" --address "$PF_ADDR" svc/opensearch "$OS_PORT":9200 &
OS_PF_PID=$!

restart_app_pf() {
    [ -n "$APP_PF_PID" ] && kill "$APP_PF_PID" 2>/dev/null || true
    kubectl port-forward -n "$NS" --address "$PF_ADDR" svc/review-service "$APP_PORT":8080 &
    APP_PF_PID=$!
    sleep 3
}

post_review() {
    local email="$1" comment="$2"
    curl -sSf -X POST http://$PF_HOST:$APP_PORT/api/reviews \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.SECRET-JWT-TOKEN" \
        -d "{\"productId\": \"OLJCESPC7Z\", \"rating\": 5, \"comment\": \"$comment\", \"userEmail\": \"$email\", \"userName\": \"Lab8 User\"}" \
        > /dev/null
}

# Search Jaeger POST traces for a marker, with retries; sets JAEGER_RESULT
jaeger_traces() {
    curl -sSf "http://$PF_HOST:$UI_PORT/jaeger/ui/api/traces?service=review-service&operation=POST%20%2Fapi%2Freviews&limit=20"
}

# NB: tail sampling (lab 7) keeps only ~25% of successful traces, so we
# re-post the review on every retry until one trace survives the sampling
wait_in_jaeger() {
    local marker="$1" email="$2" comment="$3"
    for i in $(seq 1 24); do
        if jaeger_traces | grep -q "$marker"; then return 0; fi
        post_review "$email" "$comment" || true
        sleep 5
    done
    echo "ERROR: $marker not found in Jaeger"
    return 1
}

wait_in_opensearch() {
    local marker="$1"
    for i in $(seq 1 24); do
        if curl -sS "http://$PF_HOST:$OS_PORT/otel-logs-*/_search?q=body:%22${marker}%22" \
                | grep -q "$marker"; then return 0; fi
        sleep 5
    done
    echo "ERROR: $marker not found in OpenSearch"
    return 1
}

# --- Part 1: the leak (starter build, no masking) ---
"$DIR/../../scripts/deploy.sh" -p starter
restart_app_pf
post_review "leak@example.com" "leak"

# The JWT and the email leak into the span attributes, the email into the logs
wait_in_jaeger "SECRET-JWT-TOKEN" "leak@example.com" "leak"
wait_in_jaeger "leak@example.com" "leak@example.com" "leak"
wait_in_opensearch "leak@example.com"

# --- Part 2: SDK-level masking (logs) ---
kubectl set env -n "$NS" deployment/review-service MASK_PII=true
kubectl rollout status -n "$NS" deployment/review-service --timeout=180s
restart_app_pf
post_review "sdk-mask@example.com" "sdk-mask"

# The span still leaks (SDK masking only covers logs here)...
wait_in_jaeger "sdk-mask@example.com" "sdk-mask@example.com" "sdk-mask"
# ...but the log body is redacted: the marker email never reaches OpenSearch
sleep 20
if curl -sS "http://$PF_HOST:$OS_PORT/otel-logs-*/_search?q=body:%22sdk-mask@example.com%22" \
        | grep -q "sdk-mask@example.com"; then
    echo "ERROR: sdk-mask@example.com leaked into OpenSearch despite SDK masking"
    exit 1
fi

# --- Part 3: collector-level masking (spans + logs), SDK masking off ---
helm upgrade "$RELEASE" "$CHART" \
    --version "$CHART_VERSION" \
    --namespace "$NS" \
    -f "$DIR/../../manifests/values-training.yaml" \
    ${EXTRA_VALUES:-} \
    -f "$DIR/30-otel-collector-values.yaml" \
    -f "$DIR/60-otel-metrics-values.yaml" \
    -f "$DIR/70-otel-traces-values.yaml" \
    -f "$DIR/80-otel-security-values.yaml" \
    --timeout 10m
kubectl rollout status daemonset/otel-collector-agent -n "$NS" --timeout=300s

kubectl set env -n "$NS" deployment/review-service MASK_PII-
kubectl rollout status -n "$NS" deployment/review-service --timeout=180s
restart_app_pf
sleep 5

# Only look at traces created AFTER the masking was applied: the marker
# email cannot be used to find them anymore - that is the whole point of
# the masking. Filter by timestamp instead (Jaeger start is microseconds).
START_US=$(($(date +%s%N) / 1000))
post_review "collector-mask@example.com" "collector-mask"

# A post-masking trace must exist...
found=""
for i in $(seq 1 24); do
    TRACES=$(curl -sSf "http://$PF_HOST:$UI_PORT/jaeger/ui/api/traces?service=review-service&operation=POST%20%2Fapi%2Freviews&start=$START_US&limit=20" || true)
    if echo "$TRACES" | grep -q "traceID"; then
        found=yes
        break
    fi
    post_review "collector-mask@example.com" "collector-mask" || true
    sleep 5
done
[ "$found" = "yes" ]

# ...but without the sensitive attributes (email and Authorization header
# both deleted by the collector transform)
if echo "$TRACES" | grep -q "collector-mask@example.com"; then
    echo "ERROR: collector-mask@example.com leaked into Jaeger despite collector masking"
    exit 1
fi
if echo "$TRACES" | grep -q "SECRET-JWT-TOKEN"; then
    echo "ERROR: the JWT leaked into Jaeger despite collector masking"
    exit 1
fi
# The marker email must never reach OpenSearch either
sleep 20
if curl -sS "http://$PF_HOST:$OS_PORT/otel-logs-*/_search?q=body:%22collector-mask@example.com%22" \
        | grep -q "collector-mask@example.com"; then
    echo "ERROR: collector-mask@example.com leaked into OpenSearch despite collector masking"
    exit 1
fi

echo "Lab 8 OK: PII leak demonstrated, then masked at SDK and collector levels"
