#!/bin/bash

# Lab 7 bonus solution: make the baggage visible, then sample on it.
# Assumes labs 1-7 are done (instrumented review-service, tail sampling on).
#
# Three claims of the bonus page are checked here:
#   1. the baggage is nowhere to be found until the java agent copies it into
#      span attributes - it never reaches the collector on its own;
#   2. once copied, it lands on every span of the service, down to the JDBC
#      one, and the controller's own put() overrides it from its scope on;
#   3. a string_attribute policy then keeps 100% of one tenant's traces.
#
# Order matters: the tenant policy goes in before the traces we want to read,
# otherwise an ordinary trace would face the 25% draw and could vanish.
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

start_app_port_forward() {
    # Changing an env var replaces the pod, and the port-forward dies with it.
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

# Send one review, carrying a trace id we choose and a baggage.
post_review() {
    local trace_id="$1" tenant="$2"
    curl -sSf -X POST "http://$PF_HOST:$APP_PORT/api/reviews" \
        -H "Content-Type: application/json" \
        -H "traceparent: 00-$trace_id-00f067aa0ba902b7-01" \
        -H "baggage: app.tenant=$tenant,app.review.channel=mobile" \
        -d '{"productId": "OLJCESPC7Z", "rating": 5, "comment": "baggage", "userEmail": "a@b.c", "userName": "A"}' \
        > /dev/null
}

# 32 hex chars: a fixed prefix, the run timestamp, and a counter.
trace_id() {
    printf 'ba66a9e%017x%08x' "$(date +%s)" "$1"
}

fetch_trace() {
    curl -sSf "http://$PF_HOST:$UI_PORT/jaeger/ui/api/traces/$1" || true
}

kubectl port-forward -n "$NS" --address "$PF_ADDR" svc/frontend-proxy "$UI_PORT":8080 &
PROXY_PF_PID=$!
sleep 3

# --- 1. Without the copy, nothing of the baggage reaches the collector ---
# The trace must survive sampling to be examined at all, so make it an error
# one: keep-errors retains 100% of those, whatever the draw.
kubectl set env -n "$NS" deployment/review-service \
    OTEL_JAVA_EXPERIMENTAL_SPAN_ATTRIBUTES_COPY_FROM_BAGGAGE_INCLUDE-
kubectl rollout status -n "$NS" deployment/review-service --timeout=180s
start_app_port_forward

NO_COPY_ID=$(trace_id 1)
curl -s -o /dev/null -X POST "http://$PF_HOST:$APP_PORT/api/reviews" \
    -H "Content-Type: application/json" \
    -H "traceparent: 00-$NO_COPY_ID-00f067aa0ba902b7-01" \
    -H "baggage: app.tenant=acme,app.review.channel=mobile" \
    -d '{"productId": "DOESNOTEXIST", "rating": 5, "comment": "?", "userEmail": "x@example.com", "userName": "X"}' \
    || true

found=""
for i in $(seq 1 24); do
    TRACE=$(fetch_trace "$NO_COPY_ID")
    if grep -q '"traceID"' <<< "$TRACE"; then
        found=yes
        break
    fi
    sleep 5
done
[ "$found" = "yes" ]
# The whole trace is there, and carries no trace of the two baggage keys.
if grep -q '"key":"app.tenant"' <<< "$TRACE"; then
    echo "ERROR: app.tenant found on a span while the copy is disabled"
    exit 1
fi

# --- 2. Sample on the tenant, and turn the copy on ---
helm upgrade "$RELEASE" "$CHART" \
    --version "$CHART_VERSION" \
    --namespace "$NS" \
    -f "$DIR/../../manifests/values-training.yaml" \
    ${EXTRA_VALUES:-} \
    -f "$DIR/30-otel-collector-values.yaml" \
    -f "$DIR/60-otel-metrics-values.yaml" \
    -f "$DIR/71-otel-traces-values.yaml" \
    --timeout 10m
kubectl rollout status daemonset/otel-collector-agent -n "$NS" --timeout=300s

kubectl set env -n "$NS" deployment/review-service \
    OTEL_JAVA_EXPERIMENTAL_SPAN_ATTRIBUTES_COPY_FROM_BAGGAGE_INCLUDE="app.review.channel,app.tenant"
kubectl rollout status -n "$NS" deployment/review-service --timeout=180s
start_app_port_forward

# --- 3. One acme trace, kept by the policy, read span by span ---
COPY_ID=$(trace_id 2)
post_review "$COPY_ID" acme

found=""
for i in $(seq 1 24); do
    TRACE=$(fetch_trace "$COPY_ID")
    if grep -q '"key":"app.tenant"' <<< "$TRACE"; then
        found=yes
        break
    fi
    sleep 5
done
[ "$found" = "yes" ]

# The baggage set in ReviewController overrides the incoming channel, and the
# copy reaches spans created deep below - down to the JDBC one.
TRACE_FILE=$(mktemp)
printf '%s' "$TRACE" > "$TRACE_FILE"
python3 - "$TRACE_FILE" << 'PYEOF'
import json, sys
trace = json.load(open(sys.argv[1]))["data"][0]
spans = {s["operationName"]: {t["key"]: t["value"] for t in s["tags"]} for s in trace["spans"]}

server = spans["POST /api/reviews"]
assert server.get("app.tenant") == "acme", server
assert server.get("app.review.channel") == "mobile", "server span must carry what the client sent"

insert = next(v for k, v in spans.items() if k.startswith("INSERT"))
assert insert.get("app.tenant") == "acme", "baggage must reach the JDBC span"
assert insert.get("app.review.channel") == "web", "the controller overrides the channel below its scope"
print("baggage copied down to the JDBC span, controller override visible")
PYEOF
rm -f "$TRACE_FILE"

# --- 4. Ten ordinary acme traces: none slow, none in error, all kept ---
ACME_IDS=""
for i in $(seq 3 12); do
    id=$(trace_id "$i")
    ACME_IDS="$ACME_IDS $id"
    post_review "$id" acme
done

missing=""
for i in $(seq 1 24); do
    missing=""
    for id in $ACME_IDS; do
        grep -q '"traceID"' <<< "$(fetch_trace "$id")" || missing="$missing $id"
    done
    [ -z "$missing" ] && break
    sleep 5
done
if [ -n "$missing" ]; then
    echo "ERROR: keep-tenant-acme let these traces go:$missing"
    exit 1
fi

# And the policy counter says the same thing, in the collector's own words:
# one vote per policy and per trace, so keep-tenant-acme must have voted
# "true" at least eleven times (the ten above plus the one of part 3).
kubectl port-forward -n "$NS" --address "$PF_ADDR" svc/prometheus "$PROM_PORT":9090 &
PROM_PF_PID=$!
sleep 3

found=""
for i in $(seq 1 24); do
    VOTES=$(curl -sSf -G "http://$PF_HOST:$PROM_PORT/api/v1/query" \
        --data-urlencode 'query=sum(otelcol_processor_tail_sampling_count_traces_sampled_total{policy="keep-tenant-acme",sampled="true"})' || true)
    if python3 -c '
import json, sys
r = json.load(sys.stdin).get("data", {}).get("result") or []
sys.exit(0 if r and float(r[0]["value"][1]) >= 11 else 1)
' <<< "$VOTES"; then
        found=yes
        break
    fi
    sleep 5
done
[ "$found" = "yes" ]

# --- 5. Back to the lab 7 state ---
kubectl set env -n "$NS" deployment/review-service \
    OTEL_JAVA_EXPERIMENTAL_SPAN_ATTRIBUTES_COPY_FROM_BAGGAGE_INCLUDE-
kubectl rollout status -n "$NS" deployment/review-service --timeout=180s
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

echo "Lab 7 bonus OK: baggage invisible without the copy, visible down to the JDBC"
echo "                span with it, and 10/10 acme traces kept by the tenant policy"
