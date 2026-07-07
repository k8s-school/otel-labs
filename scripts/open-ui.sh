#!/bin/bash

# Port-forward the demo frontend proxy and print the UI URLs

set -euo pipefail

DIR=$(cd "$(dirname "$0")"; pwd -P)
. "$DIR/env.sh"

cat << EOF
Opening access to the OpenTelemetry demo UIs (Ctrl+C to stop):

  Astronomy Shop   http://localhost:$UI_PORT/
  Grafana          http://localhost:$UI_PORT/grafana/
  Jaeger           http://localhost:$UI_PORT/jaeger/ui/
  Load generator   http://localhost:$UI_PORT/loadgen/
  Feature flags    http://localhost:$UI_PORT/feature

EOF

kubectl --namespace "$NS" port-forward svc/frontend-proxy "$UI_PORT":8080
