#!/bin/bash

# Port-forward the demo frontend proxy and print the UI URLs

set -euo pipefail

DIR=$(cd "$(dirname "$0")"; pwd -P)
. "$DIR/env.sh"

cat << EOF
Opening access to the OpenTelemetry demo UIs (Ctrl+C to stop):

  Astronomy Shop   http://localhost:8080/
  Grafana          http://localhost:8080/grafana/
  Jaeger           http://localhost:8080/jaeger/ui/
  Load generator   http://localhost:8080/loadgen/
  Feature flags    http://localhost:8080/feature

EOF

kubectl --namespace "$NS" port-forward svc/frontend-proxy 8080:8080
