# Shared environment for the OpenTelemetry training scripts
# Source this file, do not run it.

# Kind cluster name (ktbx default cluster is named "kind").
# Shared server: one cluster per participant, e.g. CLUSTER_NAME=$USER
CLUSTER_NAME="${CLUSTER_NAME:-otel}"

# Local ports used by port-forwards. On a shared server, give each
# participant a distinct PORT_OFFSET (e.g. student3 -> 300) so their
# port-forwards do not collide. Defaults keep the single-user behavior.
PORT_OFFSET="${PORT_OFFSET:-0}"
UI_PORT=$((8080 + PORT_OFFSET))       # demo frontend proxy (shop, Grafana, Jaeger)
APP_PORT=$((8090 + PORT_OFFSET))      # review-service API
PROM_PORT=$((9090 + PORT_OFFSET))     # Prometheus UI/API
OS_PORT=$((9200 + PORT_OFFSET))       # OpenSearch API
ZPAGES_PORT=$((55679 + PORT_OFFSET))  # collector zPages

# OpenTelemetry demo Helm release
NS="otel-demo"
RELEASE="otel-demo"
CHART="open-telemetry/opentelemetry-demo"
# Pin the chart version for reproducibility in the classroom
CHART_VERSION="0.40.9"

# Custom Spring Boot micro-service (fil rouge)
APP_NAME="review-service"
# Unique image tag per participant and per build:
# kind does not re-pull an already-loaded tag, so each build must produce a new tag
IMAGE_TAG="${IMAGE_TAG:-$(whoami)-$(date +%s)}"
