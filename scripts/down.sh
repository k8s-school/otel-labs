#!/bin/bash

# Delete the kind cluster hosting the OpenTelemetry demo

set -euxo pipefail

DIR=$(cd "$(dirname "$0")"; pwd -P)
. "$DIR/env.sh"

# Close the accesses first: their supervisor would keep reopening
# port-forwards against a cluster that no longer exists.
"$DIR/open-ui.sh" -s

kind delete cluster --name "$CLUSTER_NAME"
