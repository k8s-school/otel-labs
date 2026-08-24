#!/bin/bash

# Lab 5 solution: application logs flow to OpenSearch with trace correlation.
# Assumes labs 1-3 are done (demo + review-service running).

set -euxo pipefail

DIR=$(cd "$(dirname "$0")"; pwd -P)
NS="otel-demo"

. "$DIR/../../scripts/env.sh"

APP_PF_PID=""
OS_PF_PID=""
PROXY_PF_PID=""
cleanup() {
    [ -n "$APP_PF_PID" ] && kill "$APP_PF_PID" 2>/dev/null || true
    [ -n "$OS_PF_PID" ] && kill "$OS_PF_PID" 2>/dev/null || true
    [ -n "$PROXY_PF_PID" ] && kill "$PROXY_PF_PID" 2>/dev/null || true
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
kubectl port-forward -n "$NS" --address "$PF_ADDR" svc/frontend-proxy "$UI_PORT":8080 &
PROXY_PF_PID=$!
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

# Step 5 of the lab: the log -> trace link. The demo does NOT ship it -- the
# chart wires the other direction only (tracesToLogsV2 on the Jaeger
# datasource). The link is a dataLinks block on the OpenSearch datasource,
# applied here through the same API call the lab uses. PUT replaces the whole
# datasource, hence the complete file.
GRAFANA="http://$PF_HOST:$UI_PORT/grafana"
curl -sSf -X PUT "$GRAFANA/api/datasources/uid/webstore-logs" \
    -H "Content-Type: application/json" \
    -d @"$DIR/50-otel-logs-datasource.json" > /dev/null

# Read it back rather than trust the write: a sidecar reprovisions this
# datasource from a ConfigMap at every Grafana restart and would wipe the block.
DS=$(curl -sSf "$GRAFANA/api/datasources/uid/webstore-logs")
python3 -c '
import json, sys
ds = json.load(sys.stdin)
links = ds.get("jsonData", {}).get("dataLinks") or []
match = [l for l in links
         if l.get("field") == "traceId" and l.get("datasourceUid") == "webstore-traces"]
if not match:
    sys.exit("ERROR: no traceId -> Jaeger data link on the webstore-logs datasource")
print("Log -> trace link in place:", json.dumps(match[0]))
' <<< "$DS"

echo "Lab 5 OK: structured logs with trace correlation in OpenSearch, log -> trace link in Grafana"
