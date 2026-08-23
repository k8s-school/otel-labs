#!/bin/bash

# Lab 6 solution: business metrics written with the OpenTelemetry API
# (counter + histogram), the Micrometer bridge of the Java agent, and a
# span-derived metric (count connector).
# Assumes labs 1-3 are done.
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

# A port-forward to a service dies with the pod it selected: every rollout
# below needs a fresh one.
start_app_port_forward() {
    [ -n "$APP_PF_PID" ] && kill "$APP_PF_PID" 2>/dev/null || true
    kubectl port-forward -n "$NS" --address "$PF_ADDR" svc/review-service "$APP_PORT":8080 &
    APP_PF_PID=$!
    sleep 3
}

generate_traffic() {
    # Successful creations feed the counter and the histograms
    for i in $(seq 1 5); do
        curl -sSf -X POST http://$PF_HOST:$APP_PORT/api/reviews \
            -H "Content-Type: application/json" \
            -d "{\"productId\": \"OLJCESPC7Z\", \"rating\": $((i % 5 + 1)), \"comment\": \"metric $i\", \"userEmail\": \"user$i@example.com\", \"userName\": \"User $i\"}" \
            > /dev/null
    done
    # A failing creation (unknown product -> 500) feeds the error span count
    curl -s -o /dev/null -X POST http://$PF_HOST:$APP_PORT/api/reviews \
        -H "Content-Type: application/json" \
        -d '{"productId": "DOESNOTEXIST", "rating": 5, "comment": "?", "userEmail": "x@example.com", "userName": "X"}' \
        || true
}

check_metric_prefix() {
    local prefix="$1"
    for i in $(seq 1 24); do
        # Capture before matching: 'curl | grep -q' lets grep close the pipe on
        # the first match, curl dies of EPIPE and pipefail fails the script.
        local names
        names=$(curl -sSf "http://$PF_HOST:$PROM_PORT/api/v1/label/__name__/values" || true)
        if grep -q "\"${prefix}" <<< "$names"; then
            return 0
        fi
        generate_traffic || true
        sleep 5
    done
    echo "ERROR: no ${prefix}* metric found in Prometheus"
    return 1
}

# Part 1: the OpenTelemetry API instruments need nothing but the agent, which
# installs the SDK the API delegates to.
"$DIR/../../scripts/deploy.sh"
kubectl set env -n "$NS" deployment/review-service \
    JAVA_TOOL_OPTIONS="-javaagent:/otel/opentelemetry-javaagent.jar"
kubectl rollout status -n "$NS" deployment/review-service --timeout=180s

start_app_port_forward
kubectl port-forward -n "$NS" --address "$PF_ADDR" svc/prometheus "$PROM_PORT":9090 &
PROM_PF_PID=$!
sleep 3

generate_traffic
check_metric_prefix "reviews_created"           # OTel API counter
check_metric_prefix "reviews_creation_duration" # OTel API histogram

# Part 2: the Micrometer meter of the same service. The agent's Micrometer
# bridge is OPT-IN: without this variable the meter stays invisible.
kubectl set env -n "$NS" deployment/review-service \
    OTEL_INSTRUMENTATION_MICROMETER_ENABLED=true
kubectl rollout status -n "$NS" deployment/review-service --timeout=180s
start_app_port_forward

generate_traffic
check_metric_prefix "reviews_creation_time"     # Micrometer timer histogram

# Part 3: add the count connector to the collector
helm upgrade "$RELEASE" "$CHART" \
    --version "$CHART_VERSION" \
    --namespace "$NS" \
    -f "$DIR/../../manifests/values-training.yaml" \
    ${EXTRA_VALUES:-} \
    -f "$DIR/30-otel-collector-values.yaml" \
    -f "$DIR/60-otel-metrics-values.yaml" \
    --timeout 10m
kubectl rollout status daemonset/otel-collector-agent -n "$NS" --timeout=300s

generate_traffic
check_metric_prefix "app_spans_errors"          # count connector

echo "Lab 6 OK: business metrics (OTel API + Micrometer) and span-derived metric are in Prometheus"
