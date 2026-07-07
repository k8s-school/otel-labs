#!/bin/bash

# Build the review-service image, load it into the kind cluster and deploy it.
#
# kind does not re-pull an image tag it already knows: every build gets a
# unique tag (<profile>-<user>-<epoch>) so a redeploy always picks up the new
# image, and two participants sharing a cluster cannot overwrite each other.

set -euo pipefail

DIR=$(cd "$(dirname "$0")"; pwd -P)
. "$DIR/env.sh"

usage() {
    cat << EOF
Usage: $(basename "$0") [-p profile] [-h]
Build, load and deploy the review-service micro-service.

  -p profile   Maven profile: 'default' (agent jar available, inactive) or
               'starter' (OpenTelemetry Spring Boot Starter compiled in).
               Default: default
  -h           this message
EOF
}

PROFILE="default"
while getopts "p:h" opt; do
    case $opt in
        p) PROFILE="$OPTARG" ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

case "$PROFILE" in
    default|starter) ;;
    *) echo "ERROR: unknown profile '$PROFILE' (expected 'default' or 'starter')"; usage; exit 1 ;;
esac

APP_DIR="$DIR/../apps/review-service"
IMAGE="$APP_NAME:$PROFILE-$IMAGE_TAG"

# Old kind CLIs cannot load images into recent node images (containerd v2):
# "ERROR: failed to detect containerd snapshotter"
KIND_MINOR=$(kind version | grep -oE 'v0\.[0-9]+' | cut -d. -f2)
if [ "${KIND_MINOR:-0}" -lt 27 ]; then
    echo "ERROR: kind >= v0.27 is required to load images into this cluster"
    echo "       (found: $(kind version)) - fix: go install sigs.k8s.io/kind@v0.30.0"
    exit 1
fi

set -x

# 1. Build the image (multi-stage: maven build + jre runtime)
docker build --build-arg MAVEN_PROFILE="$PROFILE" -t "$IMAGE" "$APP_DIR"

# 2. Load it into the kind cluster (no registry needed)
kind load docker-image "$IMAGE" --name "$CLUSTER_NAME"

# 3. Remove lab toggles previously added with 'kubectl set env': kubectl
# apply RETAINS env vars added outside of it (3-way merge), which can mix
# the agent with the starter build and crash the app. Resetting BEFORE the
# apply keeps the manifest as the single source of truth.
kubectl set env -n "$NS" "deployment/$APP_NAME" \
    JAVA_TOOL_OPTIONS- MASK_PII- OTEL_INSTRUMENTATION_MICROMETER_ENABLED- \
    2>/dev/null || true

# 4. Apply the manifests with the new image tag substituted
sed "s|review-service:IMAGE_PLACEHOLDER|$IMAGE|" "$APP_DIR/k8s/review-service.yaml" \
    | kubectl apply -n "$NS" -f -

# 5. Wait for the rollout to complete
kubectl rollout status -n "$NS" "deployment/$APP_NAME" --timeout=180s

set +x
echo
echo "review-service deployed with image $IMAGE"
echo "Try it: kubectl port-forward -n $NS svc/$APP_NAME $APP_PORT:8080 &"
echo "        curl http://localhost:$APP_PORT/api/reviews"
