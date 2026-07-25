#!/bin/bash

# Pre-download the OpenTelemetry demo images on the Docker host and load them
# into a kind cluster.
#
# Why: each kind node keeps its own image store, so N participant clusters
# would download the same ~5 GB of images N times. Here the host pulls each
# image once (the Docker cache is shared by all clusters of the machine) and
# 'kind load' copies it into the node - the demo then starts without touching
# the network.
#
# Typical uses:
#   ./scripts/preload-images.sh                 # into $CLUSTER_NAME
#   ./scripts/preload-images.sh -n student3     # into another participant cluster
#   ./scripts/preload-images.sh -l              # just print the image list

set -euo pipefail

DIR=$(cd "$(dirname "$0")"; pwd -P)
. "$DIR/env.sh"

usage() {
    cat << EOF
Usage: $(basename "$0") [-n cluster] [-l] [-f] [-h]
Pull the OpenTelemetry demo images and load them into a kind cluster.

  -n cluster  kind cluster to load into (default: $CLUSTER_NAME)
  -l          list the images and exit (no pull, no load)
  -f          reload images even if the node already has them
  -h          this message
EOF
}

CLUSTER="$CLUSTER_NAME"
LIST_ONLY=false
FORCE=false
while getopts "n:lfh" opt; do
    case $opt in
        n) CLUSTER="$OPTARG" ;;
        l) LIST_ONLY=true ;;
        f) FORCE=true ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

# Images needed to build the review-service (kept on the host only: they are
# used by 'docker build', never by the cluster).
BUILD_IMAGES="maven:3.9-eclipse-temurin-21 curlimages/curl:8.11.0 eclipse-temurin:21-jre"

for cmd in docker helm; do
    command -v "$cmd" > /dev/null || { echo "ERROR: '$cmd' is required"; exit 1; }
done

# 1. Image list, rendered from the very chart and values the training installs:
#    it can never drift from what is actually deployed.
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts > /dev/null
helm repo update open-telemetry > /dev/null

# 'image:' entries, quotes stripped, ':latest' made explicit (kind and crictl
# always name images with a tag).
DEMO_IMAGES=$(helm template "$RELEASE" "$CHART" \
        --version "$CHART_VERSION" \
        --namespace "$NS" \
        -f "$DIR/../manifests/values-training.yaml" \
        ${EXTRA_VALUES:-} \
    | sed -nE "s/^[[:space:]]*-?[[:space:]]*image:[[:space:]]*[\"']?([^\"'[:space:]]+)[\"']?[[:space:]]*$/\1/p" \
    | awk -F/ '{ if ($NF !~ /:/) $0 = $0 ":latest"; print }' \
    | sort -u)

if [ "$LIST_ONLY" = true ]; then
    echo "# demo images (pulled and loaded into the cluster)"
    echo "$DEMO_IMAGES"
    echo "# build images (pulled on the host only)"
    printf '%s\n' $BUILD_IMAGES
    exit 0
fi

command -v kind > /dev/null || { echo "ERROR: 'kind' is required"; exit 1; }
kind get clusters 2>/dev/null | grep -qx "$CLUSTER" || {
    echo "ERROR: no kind cluster named '$CLUSTER' (create it with scripts/up.sh -c)"
    exit 1
}

# 2. Pull on the host. Parallel: the bottleneck is the network, not the CPU.
echo "Pulling $(printf '%s\n' $DEMO_IMAGES $BUILD_IMAGES | wc -l) images on the host (already-present ones are skipped)..."
printf '%s\n' $DEMO_IMAGES $BUILD_IMAGES \
    | xargs -P 4 -I{} sh -c 'docker image inspect {} > /dev/null 2>&1 || docker pull -q {}'

# 3. Load into the cluster nodes. Images already imported are skipped: 'kind
#    load' re-exports the whole tarball every time, which is the slow part.
TO_LOAD="$DEMO_IMAGES"
if [ "$FORCE" != true ]; then
    # Names as containerd stores them: docker.io/library/busybox:latest for
    # busybox:latest. Normalize both sides before comparing.
    PRESENT=$(docker exec "$CLUSTER-control-plane" crictl images 2>/dev/null \
        | awk 'NR > 1 { print $1 ":" $2 }' \
        | sed -E 's#^docker\.io/(library/)?##' \
        | sort -u || true)
    TO_LOAD=$(printf '%s\n' $DEMO_IMAGES | while read -r img; do
        printf '%s\n' "$PRESENT" | grep -qxF "${img#docker.io/}" || echo "$img"
    done)
fi

if [ -z "$TO_LOAD" ]; then
    echo "Cluster '$CLUSTER' already has all the demo images."
    exit 0
fi

echo "Loading $(printf '%s\n' $TO_LOAD | wc -l) images into cluster '$CLUSTER' (a few minutes)..."
# shellcheck disable=SC2086
kind load docker-image --name "$CLUSTER" $TO_LOAD

echo "Images preloaded into '$CLUSTER'."
