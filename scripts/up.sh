#!/bin/bash

# Create the kind cluster and install the OpenTelemetry demo
# (collector, Grafana, Jaeger, Prometheus, OpenSearch, Astronomy Shop micro-services)

set -euo pipefail

DIR=$(cd "$(dirname "$0")"; pwd -P)
. "$DIR/env.sh"

usage() {
    cat << EOF
Usage: $(basename "$0") [-c] [-h]
Create a kind cluster and install the OpenTelemetry demo.

  -c    also (re)create the kind cluster (default: reuse current kubectl context)
  -h    this message

Additional values files can be passed through EXTRA_VALUES, e.g.:
  EXTRA_VALUES="-f manifests/values-ci.yaml" $(basename "$0")
EOF
}

CREATE_CLUSTER=false
while getopts "ch" opt; do
    case $opt in
        c) CREATE_CLUSTER=true ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

# Check prerequisites
for cmd in docker kubectl helm; do
    command -v "$cmd" > /dev/null || { echo "ERROR: '$cmd' is required"; exit 1; }
done

if [ "$CREATE_CLUSTER" = true ]; then
    command -v ktbx > /dev/null || { echo "ERROR: 'ktbx' is required (go install github.com/k8s-school/ktbx@latest)"; exit 1; }
    ktbx create -s -n "$CLUSTER_NAME"
    kubectl config use-context "kind-$CLUSTER_NAME"
fi

kubectl cluster-info > /dev/null || { echo "ERROR: no reachable Kubernetes cluster"; exit 1; }

# Install the OpenTelemetry demo (version pinned for reproducibility)
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update open-telemetry

helm upgrade --install "$RELEASE" "$CHART" \
    --version "$CHART_VERSION" \
    --namespace "$NS" --create-namespace \
    -f "$DIR/../manifests/values-training.yaml" \
    ${EXTRA_VALUES:-} \
    --timeout 10m

echo "Waiting for all demo pods to be ready (this can take a few minutes)..."
# Only wait for the demo pods (label set by the chart): a participant's
# review-service left broken must not block the stack check.
# Retry: pods replaced during the wait (e.g. a rollout in progress) make
# 'kubectl wait' fail with NotFound even though the stack converges
ready=false
for i in 1 2 3; do
    if kubectl wait --for=condition=Ready pods -l opentelemetry.io/name \
            -n "$NS" --timeout=600s; then
        ready=true
        break
    fi
    sleep 10
done
if [ "$ready" != true ]; then
    echo "ERROR: pods not ready"
    exit 1
fi

kubectl get pods -n "$NS"
echo
echo "OpenTelemetry demo is up. Run scripts/open-ui.sh to access the UIs."
