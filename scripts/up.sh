#!/bin/bash

# Create the kind cluster and install the OpenTelemetry demo
# (collector, Grafana, Jaeger, Prometheus, OpenSearch, Astronomy Shop micro-services)

set -euo pipefail

DIR=$(cd "$(dirname "$0")"; pwd -P)
. "$DIR/env.sh"

usage() {
    cat << EOF
Usage: $(basename "$0") [-P] [-h]
Make sure the kind cluster '$CLUSTER_NAME' exists, then install the OpenTelemetry demo.

The cluster is reused when it is already there, and created when it is not, so
this script is always safe to re-run: it never destroys the cluster you are
working in. Deleting it is a separate, explicit step (scripts/down.sh).

  -P    prepare only: make sure the cluster exists and preload its images, then
        STOP before the helm install. Used by 'make precreate' to get a room
        ready ahead of a session; the participant then runs '$(basename "$0")'
        with no flag for a fast install on the ready cluster.
  -h    this message

The demo images are preloaded on every run, and those the node already has are
skipped - so it costs nothing once done. Set SKIP_PRELOAD=true to install
straight from the internet instead.
Additional values files can be passed through EXTRA_VALUES, e.g.:
  EXTRA_VALUES="-f manifests/values-ci.yaml" $(basename "$0")
EOF
}

PREPARE_ONLY=false
while getopts "Ph" opt; do
    case $opt in
        P) PREPARE_ONLY=true ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done
PRELOAD=true
if [ "${SKIP_PRELOAD:-false}" = true ]; then
    PRELOAD=false
fi

# Check prerequisites
for cmd in docker kind kubectl helm; do
    command -v "$cmd" > /dev/null || { echo "ERROR: '$cmd' is required"; exit 1; }
done

# Reuse the cluster when it exists, create it when it does not - and never
# recreate it: re-running this script must not cost a participant the cluster
# they have been working in for two days. down.sh is how you delete one.
if kind get clusters 2> /dev/null | grep -qx "$CLUSTER_NAME"; then
    echo "Cluster '$CLUSTER_NAME' is already there, reusing it."
else
    command -v ktbx > /dev/null || { echo "ERROR: 'ktbx' is required (go install github.com/k8s-school/ktbx@latest)"; exit 1; }
    echo "No cluster '$CLUSTER_NAME' yet, creating it."
    ktbx create -s -n "$CLUSTER_NAME"
fi
kubectl config use-context "kind-$CLUSTER_NAME"

kubectl cluster-info > /dev/null || { echo "ERROR: no reachable Kubernetes cluster"; exit 1; }

# kind caps its CNI (kindnet) at 50Mi, which is exactly its working set: after
# any memory pressure on the host it re-reads its binary from disk in a loop
# (2,000+ refaults/s per node, measured on the training server 2026-09-13, nine
# clusters on one 5k IOPS volume). Same mechanism as the demo limits raised in
# values-training.yaml. Idempotent: a no-op when the limit is already there.
kubectl -n kube-system set resources daemonset kindnet -c kindnet-cni \
    --requests=memory=50Mi --limits=memory=100Mi > /dev/null

# Pull the demo images once on the host and inject them into the kind node:
# much faster than letting each cluster download ~5 GB from the internet.
if [ "$PRELOAD" = true ]; then
    "$DIR/preload-images.sh" -n "$CLUSTER_NAME"
fi

# Prepare-only: the cluster exists and its images are loaded, but the demo is
# not installed yet. That last helm install is left to the participant, in
# session, on this ready cluster (a couple of minutes, no image pull).
if [ "$PREPARE_ONLY" = true ]; then
    echo "Cluster '$CLUSTER_NAME' ready, images preloaded. Run '$(basename "$0")' (no flag) to install the demo."
    exit 0
fi

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

# The label above only covers the shop workloads. The backends and the collector
# come from subcharts and carry their own labels, so they were not waited for:
# a lab could then query Grafana or Prometheus before they serve (the
# frontend-proxy answers 503), and the collector is what every later lab needs.
for workload in deployment/grafana deployment/jaeger deployment/prometheus \
                statefulset/opensearch daemonset/otel-collector-agent; do
    kubectl rollout status "$workload" -n "$NS" --timeout=600s
done

kubectl get pods -n "$NS"
echo
echo "OpenTelemetry demo is up. Run scripts/open-ui.sh to open the accesses."
