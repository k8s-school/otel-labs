#!/bin/bash

# Build the review-service image, load it into the kind cluster and deploy it.
#
# kind does not re-pull an image tag it already knows: every build gets a
# unique tag (<maven profile>-<user>-<epoch>) so a redeploy always picks up the
# new image, and two participants sharing a cluster cannot overwrite each other.

set -euo pipefail

DIR=$(cd "$(dirname "$0")"; pwd -P)
. "$DIR/env.sh"

usage() {
    cat << EOF
Usage: $(basename "$0") [-p variant] [-h]
Build, load and deploy the review-service micro-service.

  -p variant   how the service ends up instrumented:
                 default  nothing active. The agent jar is in the image but
                          stays off - Lab 2 (part 1) switches it on by hand.
                 agent    the same image, with the Java agent switched on for
                          you (JAVA_TOOL_OPTIONS, set after the rollout).
                 starter  the OpenTelemetry Spring Boot Starter compiled in.
               Default: default
  -h           this message

The three are mutually exclusive on purpose: the agent on top of a starter
build would run two SDKs in one JVM, with no telling which produced what.
'agent' is a shortcut for demos and rehearsals - the labs do it by hand,
because that is the exercise.
EOF
}

VARIANT="default"
while getopts "p:h" opt; do
    case $opt in
        p) VARIANT="$OPTARG" ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

# Split the variant into the two things it really means: which Maven profile
# builds the image, and whether the agent is switched on at runtime. 'agent' is
# NOT a Maven profile - it is the 'default' image plus an env var - so it has to
# build as 'default'; passing 'agent' to mvn -P would just fail the build.
case "$VARIANT" in
    default) MAVEN_PROFILE=default; AGENT=false ;;
    agent)   MAVEN_PROFILE=default; AGENT=true  ;;
    starter) MAVEN_PROFILE=starter; AGENT=false ;;
    *) echo "ERROR: unknown variant '$VARIANT' (expected 'default', 'agent' or 'starter')"; usage; exit 1 ;;
esac

APP_DIR="$DIR/../apps/review-service"
# Tag on the Maven profile rather than the variant: 'default' and 'agent' build
# the very same image, and tagging them apart would build and 'kind load' a
# second, identical copy for nothing.
IMAGE="$APP_NAME:$MAVEN_PROFILE-$IMAGE_TAG"

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
docker build --build-arg MAVEN_PROFILE="$MAVEN_PROFILE" -t "$IMAGE" "$APP_DIR"

# 2. Load it into the kind cluster (no registry needed)
kind load docker-image "$IMAGE" --name "$CLUSTER_NAME"

# 3. Remove lab toggles previously added with 'kubectl set env': kubectl
# apply RETAINS env vars added outside of it (3-way merge), which would leave
# the agent enabled on a starter build - two SDKs in one JVM, and no telling
# which one produced what. Resetting BEFORE the apply keeps the manifest as
# the single source of truth.
kubectl set env -n "$NS" "deployment/$APP_NAME" \
    JAVA_TOOL_OPTIONS- OTEL_INSTRUMENTATION_MICROMETER_ENABLED- \
    2>/dev/null || true

# 4. Apply the manifests with the new image tag substituted
sed "s|review-service:IMAGE_PLACEHOLDER|$IMAGE|" "$APP_DIR/k8s/review-service.yaml" \
    | kubectl apply -n "$NS" -f -

# 5. Wait for the rollout to complete
kubectl rollout status -n "$NS" "deployment/$APP_NAME" --timeout=180s

# 6. Switch the agent on, for -p agent only. This has to come AFTER the rollout:
# step 3 clears JAVA_TOOL_OPTIONS on purpose, so setting it before the apply
# would just be undone. It costs a second, quick rollout.
if [ "$AGENT" = true ]; then
    kubectl set env -n "$NS" "deployment/$APP_NAME" \
        JAVA_TOOL_OPTIONS="-javaagent:/otel/opentelemetry-javaagent.jar"
    kubectl rollout status -n "$NS" "deployment/$APP_NAME" --timeout=180s
fi

set +x
echo
echo "review-service deployed with image $IMAGE (variant: $VARIANT)"
if [ "$AGENT" = true ]; then
    echo "Java agent ACTIVE: JAVA_TOOL_OPTIONS=-javaagent:/otel/opentelemetry-javaagent.jar"
fi
# scripts/open-ui.sh keeps the access open across this rollout
echo "Try it: curl http://$PF_HOST:$APP_PORT/api/reviews"
