#!/bin/bash

# Lab 3 solution: extend the collector configuration with hostmetrics and
# postgresql receivers, then check the new metrics land in Prometheus.
# Assumes labs 1 and 2 are done (demo + review-service running).
#
# EXTRA_VALUES can carry additional values files (e.g. CI):
#   EXTRA_VALUES="-f manifests/values-ci.yaml" ./30-otel-collector-solution.sh

set -euxo pipefail

DIR=$(cd "$(dirname "$0")"; pwd -P)
NS="otel-demo"

. "$DIR/../../scripts/env.sh"

# Apply the reference collector configuration on top of the training values
helm upgrade "$RELEASE" "$CHART" \
    --version "$CHART_VERSION" \
    --namespace "$NS" \
    -f "$DIR/../../manifests/values-training.yaml" \
    ${EXTRA_VALUES:-} \
    -f "$DIR/30-otel-collector-values.yaml" \
    --timeout 10m

kubectl rollout status daemonset/otel-collector-agent -n "$NS" --timeout=300s

# zPages answers and shows the metrics pipeline
kubectl port-forward -n "$NS" --address "$PF_ADDR" daemonset/otel-collector-agent "$ZPAGES_PORT":55679 &
ZPAGES_PF_PID=$!
kubectl port-forward -n "$NS" --address "$PF_ADDR" svc/prometheus "$PROM_PORT":9090 &
PROM_PF_PID=$!
trap 'kill $ZPAGES_PF_PID $PROM_PF_PID 2>/dev/null || true' EXIT
sleep 3

curl -sSf http://$PF_HOST:$ZPAGES_PORT/debug/pipelinez | grep -q "hostmetrics"
curl -sSf http://$PF_HOST:$ZPAGES_PORT/debug/pipelinez | grep -q "postgresql"

# Both system and postgresql metrics must reach Prometheus
# (wait up to 2 minutes for the first scrapes to be exported)
check_metric_prefix() {
    local prefix="$1"
    for i in $(seq 1 24); do
        if curl -sSf "http://$PF_HOST:$PROM_PORT/api/v1/label/__name__/values" \
                | grep -q "\"${prefix}"; then
            return 0
        fi
        sleep 5
    done
    echo "ERROR: no ${prefix}* metric found in Prometheus"
    return 1
}

# NB: do NOT check "system_" alone. The Python demo services (load-generator,
# recommendation, product-reviews) are auto-instrumented with
# opentelemetry-instrumentation-system-metrics and already push system.cpu.time,
# system.memory.usage... over OTLP, so "system_" is present even without the
# hostmetrics receiver. Only the "load" scraper produces the node load average.
check_metric_prefix "system_cpu_load_average"
check_metric_prefix "postgresql_"

echo "Lab 3 OK: system and PostgreSQL metrics are collected"
