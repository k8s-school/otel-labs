#!/bin/bash

# Port-forward the demo frontend proxy and print the UI URLs.
#
# The port is always 8080 (UI_PORT). On a shared server what differs is the
# bind address: PF_ADDR/PF_HOST identify the participant (see env.sh).

set -euo pipefail

DIR=$(cd "$(dirname "$0")"; pwd -P)
. "$DIR/env.sh"

cat << EOF
Opening access to the OpenTelemetry demo UIs (Ctrl+C to stop):

  Astronomy Shop   http://$PF_HOST:$UI_PORT/
  Grafana          http://$PF_HOST:$UI_PORT/grafana/
  Jaeger           http://$PF_HOST:$UI_PORT/jaeger/ui/
  Load generator   http://$PF_HOST:$UI_PORT/loadgen/
  Feature flags    http://$PF_HOST:$UI_PORT/feature

EOF

if [ "$PF_ADDR" != "127.0.0.1" ]; then
    cat << EOF
Shared server: forward the port from your workstation first, e.g.
  ssh -L $UI_PORT:$PF_ADDR:$UI_PORT $(id -un)@<server>
then browse http://localhost:$UI_PORT/

EOF
fi

kubectl --namespace "$NS" port-forward --address "$PF_ADDR" svc/frontend-proxy "$UI_PORT":8080
