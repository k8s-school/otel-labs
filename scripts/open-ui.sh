#!/bin/bash

# Port-forward the demo frontend proxy and print the UI URLs.
#
# The local port is UI_PORT (see env.sh): 8080 for a single user, 808<N> for
# the account student<N> on a shared server.

set -euo pipefail

DIR=$(cd "$(dirname "$0")"; pwd -P)
. "$DIR/env.sh"

cat << EOF
Opening access to the OpenTelemetry demo UIs on port $UI_PORT (Ctrl+C to stop):

  Astronomy Shop   http://localhost:$UI_PORT/
  Grafana          http://localhost:$UI_PORT/grafana/
  Jaeger           http://localhost:$UI_PORT/jaeger/ui/
  Load generator   http://localhost:$UI_PORT/loadgen/
  Feature flags    http://localhost:$UI_PORT/feature

EOF

if [ "$PORT_OFFSET" -ne 0 ]; then
    cat << EOF
Shared server: forward the port from your workstation first, e.g.
  ssh -L $UI_PORT:localhost:$UI_PORT $(id -un)@<server>

EOF
fi

kubectl --namespace "$NS" port-forward svc/frontend-proxy "$UI_PORT":8080
