# Shared environment for the OpenTelemetry training scripts
# Source this file, do not run it.

# Kind cluster name (ktbx default cluster is named "kind"). On the shared
# server there is one cluster per participant, named after the account:
# student3 owns the cluster 'student3'.
#
# Derived from the login name for the same reason as PF_ADDR below: a
# non-interactive shell (ssh <host> '<command>', a script, a cron job) never
# reads ~/.bashrc, where the provisioning exports CLUSTER_NAME. Without this it
# would fall back to 'otel' and deploy.sh would stop on
# 'kind load ... no nodes found for cluster "otel"'.
if [ -z "${CLUSTER_NAME:-}" ]; then
    case "$(id -un)" in
        # k8s-server, ansible role 'participants': one cluster per account.
        student[1-9]|student[1-9][0-9]|student1[0-9][0-9]|trainer)
            CLUSTER_NAME="$(id -un)" ;;
        # Individual workstation: the single cluster of the labs.
        *) CLUSTER_NAME="otel" ;;
    esac
fi

# Address the port-forwards bind to, and the name used to reach them.
# Everybody uses the same ports; on a shared server it is the address that
# differs, so two participants never fight over a port: student<N> binds
# 127.0.0.<N> (the whole 127.0.0.0/8 is routed to lo on Linux, nothing to
# configure), student3 -> 127.0.0.3.
#
# Derived from the login name so a participant never has to set it, and so a
# non-interactive shell (ssh <host> '<command>', a script, a cron job) that
# never reads ~/.bashrc still binds the right address instead of silently
# colliding with a neighbour on 127.0.0.1. The training server provisioning
# (k8s-server, ansible role 'participants') exports both variables anyway,
# and they win over what is computed here.
if [ -z "${PF_ADDR:-}" ]; then
    case "$(id -un)" in
        # student1 .. student199: one loopback address per participant.
        student[1-9]|student[1-9][0-9]|student1[0-9][0-9])
            PF_ADDR="127.0.0.$(id -un | tr -cd '0-9')" ;;
        # The instructor demoes on the same server as student1, who owns
        # 127.0.0.1: give the trainer an address of its own, out of the
        # participant range.
        trainer) PF_ADDR="127.0.0.200" ;;
        *) PF_ADDR="127.0.0.1" ;;
    esac
fi
# Name used in URLs. The provisioning adds a matching /etc/hosts entry
# (127.0.0.3 localhost3) - a name that reads like the 'localhost' of the labs,
# because that is exactly what it is. Nicer to read but not required: without
# it the address itself does the job.
if [ -z "${PF_HOST:-}" ]; then
    PF_HOST="$PF_ADDR"
    if [ "$PF_ADDR" = "127.0.0.1" ]; then
        PF_HOST="localhost"
    else
        alias_name="localhost${PF_ADDR##*.}"
        if getent hosts "$alias_name" > /dev/null 2>&1; then
            PF_HOST="$alias_name"
        fi
        unset alias_name
    fi
fi

# Local ports used by port-forwards. Same values for everyone.
UI_PORT=8080       # demo frontend proxy (shop, Grafana, Jaeger)
APP_PORT=8090      # review-service API
PROM_PORT=9090     # Prometheus UI/API
OS_PORT=9200       # OpenSearch API
ZPAGES_PORT=55679  # collector zPages

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
