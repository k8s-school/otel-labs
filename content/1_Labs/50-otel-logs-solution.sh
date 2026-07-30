#!/bin/bash

# Lab 5 solution: application logs flow to OpenSearch with trace correlation.
# Assumes labs 1-3 are done (demo + review-service running).

set -euxo pipefail

DIR=$(cd "$(dirname "$0")"; pwd -P)
NS="otel-demo"

. "$DIR/../../scripts/env.sh"

APP_PF_PID=""
OS_PF_PID=""
cleanup() {
    [ -n "$APP_PF_PID" ] && kill "$APP_PF_PID" 2>/dev/null || true
    [ -n "$OS_PF_PID" ] && kill "$OS_PF_PID" 2>/dev/null || true
}
trap cleanup EXIT

# Redeploy the DEFAULT build then activate the Java agent (it also ships
# the logs). Lab 2 left the starter build deployed: agent and starter must
# never cohabit (both register the OpenTelemetry SDK).
"$DIR/../../scripts/deploy.sh"
kubectl set env -n "$NS" deployment/review-service \
    JAVA_TOOL_OPTIONS="-javaagent:/otel/opentelemetry-javaagent.jar"
kubectl rollout status -n "$NS" deployment/review-service --timeout=180s

kubectl port-forward -n "$NS" --address "$PF_ADDR" svc/review-service "$APP_PORT":8080 &
APP_PF_PID=$!
kubectl port-forward -n "$NS" --address "$PF_ADDR" svc/opensearch "$OS_PORT":9200 &
OS_PF_PID=$!
sleep 3

# Generate correlated logs
curl -sSf http://$PF_HOST:$APP_PORT/api/reviews > /dev/null
curl -sSf -X POST http://$PF_HOST:$APP_PORT/api/reviews \
    -H "Content-Type: application/json" \
    -d '{"productId": "OLJCESPC7Z", "rating": 4, "comment": "Nice!", "userEmail": "marie.curie@example.com", "userName": "Marie Curie"}' \
    > /dev/null

# review-service logs must reach the otel-logs index with a traceId
# (wait up to 2 minutes for the pipeline)
QUERY='{"size": 5, "query": {"bool": {"must": [
  {"match_phrase": {"body": "Creating review for product"}},
  {"exists": {"field": "traceId"}}
]}}}'

for i in $(seq 1 24); do
    RESULT=$(curl -sS "http://$PF_HOST:$OS_PORT/otel-logs-*/_search" \
        -H "Content-Type: application/json" -d "$QUERY" || true)
    if grep -q "Creating review for product" <<< "$RESULT"; then
        break
    fi
    sleep 5
done

grep -q "Creating review for product" <<< "$RESULT"
grep -q "review-service" <<< "$RESULT"
grep -Eq '"traceId":"[0-9a-f]{32}"' <<< "$RESULT"

echo "Lab 5 OK: structured logs with trace correlation in OpenSearch"
