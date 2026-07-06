#!/bin/bash

# Delete the kind cluster hosting the OpenTelemetry demo

set -euxo pipefail

DIR=$(cd "$(dirname "$0")"; pwd -P)
. "$DIR/env.sh"

kind delete cluster --name "$CLUSTER_NAME"
