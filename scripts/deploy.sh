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

set -x

# 1. Build the image (multi-stage: maven build + jre runtime)
docker build --build-arg MAVEN_PROFILE="$PROFILE" -t "$IMAGE" "$APP_DIR"

# 2. Load it into the kind cluster (no registry needed)
kind load docker-image "$IMAGE" --name "$CLUSTER_NAME"

# 3. Apply the manifests with the new image tag substituted
sed "s|review-service:IMAGE_PLACEHOLDER|$IMAGE|" "$APP_DIR/k8s/review-service.yaml" \
    | kubectl apply -n "$NS" -f -

# 4. Wait for the rollout to complete
kubectl rollout status -n "$NS" "deployment/$APP_NAME" --timeout=180s

set +x
echo
echo "review-service deployed with image $IMAGE"
echo "Try it: kubectl port-forward -n $NS svc/$APP_NAME 8090:8080 &"
echo "        curl http://localhost:8090/api/reviews"
