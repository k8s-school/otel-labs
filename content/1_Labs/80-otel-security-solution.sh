#!/bin/bash

# Lab 8 solution: PII leak, fixed at the source, then netted at the collector.
# Assumes labs 1-7 are done - the application is the one lab 7 left running,
# java agent included. No starter build here: the leak comes from our own
# code, so the fix is our own code.
#
# Part 2 edits ReviewController.java the way the lab asks the reader to, and
# puts it back afterwards (the file is restored from a copy, not from git, so
# a dirty working tree is left alone).
#
# EXTRA_VALUES can carry additional values files (e.g. CI).

set -euxo pipefail

DIR=$(cd "$(dirname "$0")"; pwd -P)
NS="otel-demo"

. "$DIR/../../scripts/env.sh"

CONTROLLER="$DIR/../../apps/review-service/src/main/java/fr/k8sschool/reviews/ReviewController.java"
CONTROLLER_BACKUP=$(mktemp)
cp "$CONTROLLER" "$CONTROLLER_BACKUP"

APP_PF_PID=""
PROXY_PF_PID=""
OS_PF_PID=""
cleanup() {
    # The faulty code is the starting point of the lab: always put it back.
    cp "$CONTROLLER_BACKUP" "$CONTROLLER"
    rm -f "$CONTROLLER_BACKUP"
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

# deploy.sh reapplies the manifest, which drops JAVA_TOOL_OPTIONS: without
# this the agent stays off and nothing is emitted at all.
redeploy_with_agent() {
    "$DIR/../../scripts/deploy.sh"
    kubectl set env -n "$NS" deployment/review-service \
        JAVA_TOOL_OPTIONS="-javaagent:/otel/opentelemetry-javaagent.jar"
    kubectl rollout status -n "$NS" deployment/review-service --timeout=180s
    restart_app_pf
}

post_review() {
    local email="$1" comment="$2"
    curl -sSf -X POST http://$PF_HOST:$APP_PORT/api/reviews \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.SECRET-JWT-TOKEN" \
        -d "{\"productId\": \"OLJCESPC7Z\", \"rating\": 5, \"comment\": \"$comment\", \"userEmail\": \"$email\", \"userName\": \"Lab8 User\"}" \
        > /dev/null
}

jaeger_traces() {
    local start="${1:-}"
    curl -sSf "http://$PF_HOST:$UI_PORT/jaeger/ui/api/traces?service=review-service&operation=POST%20%2Fapi%2Freviews&limit=20${start:+&start=$start}"
}

# NB: tail sampling (lab 7) keeps only ~25% of successful traces, so we
# re-post the review on every retry until one trace survives the sampling
wait_in_jaeger() {
    local marker="$1" email="$2" comment="$3"
    for i in $(seq 1 24); do
        # Capture before matching: piping into 'grep -q' makes grep close the
        # pipe on the first match, the producer dies of EPIPE and pipefail turns
        # that into a failure -- at random, depending on where the match falls.
        local traces
        traces=$(jaeger_traces || true)
        if grep -q "$marker" <<< "$traces"; then return 0; fi
        post_review "$email" "$comment" || true
        sleep 5
    done
    echo "ERROR: $marker not found in Jaeger"
    return 1
}

wait_in_opensearch() {
    local marker="$1"
    for i in $(seq 1 24); do
        local hits
        hits=$(curl -sS "http://$PF_HOST:$OS_PORT/otel-logs-*/_search?q=body:%22${marker}%22" || true)
        if grep -q "$marker" <<< "$hits"; then return 0; fi
        sleep 5
    done
    echo "ERROR: $marker not found in OpenSearch"
    return 1
}

# A trace posted after $1 must exist, and must not carry the marker. Sets TRACES.
assert_clean_trace_after() {
    local start_us="$1" marker="$2" comment="$3"
    post_review "$marker" "$comment"
    local found=""
    for i in $(seq 1 24); do
        TRACES=$(jaeger_traces "$start_us" || true)
        if grep -q "traceID" <<< "$TRACES"; then
            found=yes
            break
        fi
        post_review "$marker" "$comment" || true
        sleep 5
    done
    [ "$found" = "yes" ]
    if grep -q "$marker" <<< "$TRACES"; then
        echo "ERROR: $marker leaked into Jaeger"
        return 1
    fi
    if grep -q "SECRET-JWT-TOKEN" <<< "$TRACES"; then
        echo "ERROR: the JWT leaked into Jaeger"
        return 1
    fi
    # And nothing in the logs either.
    sleep 20
    local hits
    hits=$(curl -sS "http://$PF_HOST:$OS_PORT/otel-logs-*/_search?q=body:%22${marker}%22")
    if grep -q "$marker" <<< "$hits"; then
        echo "ERROR: $marker leaked into OpenSearch"
        return 1
    fi
}

# --- Part 1: the leak, on the application lab 7 left running ---
restart_app_pf
post_review "leak@example.com" "leak"

# The JWT and the email leak into the span attributes, the email into the logs
wait_in_jaeger "SECRET-JWT-TOKEN" "leak@example.com" "leak"
wait_in_jaeger "leak@example.com" "leak@example.com" "leak"
wait_in_opensearch "leak@example.com"

# --- Part 2: fix the code that writes the PII ---
# The three faulty lines of the lab, removed the way the reader is asked to.
python3 - "$CONTROLLER" << 'PYEOF'
import re, sys

path = sys.argv[1]
src = open(path).read()

faulty = '''        Span span = Span.current();
        span.setAttribute("user.email", String.valueOf(review.getUserEmail()));
        if (authorization != null) {
            span.setAttribute("http.request.header.authorization", authorization);
        }
        logger.info("Creating review for product {} by {} <{}>",
                review.getProductId(), review.getUserName(), review.getUserEmail());
'''
fixed = '''        logger.info("Creating review for product {}", review.getProductId());
'''
if faulty not in src:
    sys.exit("ERROR: the faulty block is not where the lab says it is - update this script")
open(path, "w").write(src.replace(faulty, fixed))
print("ReviewController.java: three faulty lines removed")
PYEOF

redeploy_with_agent
FIX_START_US=$(($(date +%s%N) / 1000))
assert_clean_trace_after "$FIX_START_US" "fixed@example.com" "fixed"

# --- Part 3: the collector net, checked by putting the fault back ---
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

# The faulty code is back - as if a colleague had reintroduced it.
cp "$CONTROLLER_BACKUP" "$CONTROLLER"
redeploy_with_agent
NET_START_US=$(($(date +%s%N) / 1000))
assert_clean_trace_after "$NET_START_US" "collector-mask@example.com" "collector-mask"

echo "Lab 8 OK: leak demonstrated, fixed in the code, and still caught by the"
echo "          collector once the faulty code is back"
