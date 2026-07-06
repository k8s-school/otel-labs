#!/bin/bash

# Lab 2 solution: instrument review-service without code changes,
# first with the OpenTelemetry Java agent, then with the Spring Boot Starter.
# Assumes Lab 1 is done (demo running in the otel-demo namespace).

set -euxo pipefail

DIR=$(cd "$(dirname "$0")"; pwd -P)
NS="otel-demo"

APP_PF_PID=""
PROXY_PF_PID=""

cleanup() {
    [ -n "$APP_PF_PID" ] && kill "$APP_PF_PID" 2>/dev/null || true
    [ -n "$PROXY_PF_PID" ] && kill "$PROXY_PF_PID" 2>/dev/null || true
}
trap cleanup EXIT

# Port-forward to the Jaeger UI (through the demo frontend proxy)
kubectl port-forward -n "$NS" svc/frontend-proxy 8080:8080 &
PROXY_PF_PID=$!
sleep 3

# (Re)start the port-forward to review-service: a port-forward is bound to a
# single pod, it must be restarted after each rollout
restart_app_pf() {
    [ -n "$APP_PF_PID" ] && kill "$APP_PF_PID" 2>/dev/null || true
    kubectl port-forward -n "$NS" svc/review-service 8090:8080 &
    APP_PF_PID=$!
    sleep 3
}

generate_traffic() {
    curl -sSf http://localhost:8090/api/reviews > /dev/null
    curl -sSf http://localhost:8090/api/reviews/product/OLJCESPC7Z > /dev/null
    curl -sSf -X POST http://localhost:8090/api/reviews \
        -H "Content-Type: application/json" \
        -d '{"productId": "OLJCESPC7Z", "rating": 5, "comment": "Great scope!", "userEmail": "jean.dupont@example.com", "userName": "Jean Dupont"}' \
        > /dev/null
}

# Wait until Jaeger returns review-service traces produced by the given
# telemetry distro ("opentelemetry-java-instrumentation" for the agent,
# "opentelemetry-spring-boot-starter" for the starter)
wait_for_traces() {
    local distro="$1"
    for i in $(seq 1 24); do
        if curl -sSf "http://localhost:8080/jaeger/ui/api/traces?service=review-service&limit=20" \
                | grep -q "$distro"; then
            return 0
        fi
        generate_traffic || true
        sleep 5
    done
    echo "ERROR: no review-service trace from $distro found in Jaeger"
    return 1
}

# --- Part 1: deploy the service as delivered (not instrumented) ---
"$DIR/../../scripts/deploy.sh"
restart_app_pf
generate_traffic

# --- Part 1: activate the Java agent ---
# Equivalent to uncommenting JAVA_TOOL_OPTIONS in k8s/review-service.yaml
kubectl set env -n "$NS" deployment/review-service \
    JAVA_TOOL_OPTIONS="-javaagent:/otel/opentelemetry-javaagent.jar"
kubectl rollout status -n "$NS" deployment/review-service --timeout=180s
restart_app_pf
generate_traffic
wait_for_traces "opentelemetry-java-instrumentation"

# --- Part 2: rebuild with the Spring Boot Starter (agent off) ---
kubectl set env -n "$NS" deployment/review-service JAVA_TOOL_OPTIONS-
"$DIR/../../scripts/deploy.sh" -p starter
restart_app_pf
generate_traffic
wait_for_traces "opentelemetry-spring-boot-starter"

echo "Lab 2 OK: review-service traced by both the Java agent and the Spring Boot Starter"
