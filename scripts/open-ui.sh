#!/bin/bash

# Open every access the labs need, and keep them open.
#
# The labs talk about URLs, not about kubectl: this script owns all the
# port-forwards. Each one runs under a supervisor that restarts it when it
# dies - which happens on every redeploy, because 'kubectl port-forward' binds
# one pod and that pod gets replaced.
#
# The ports are always the same (see env.sh). On a shared server what differs
# is the bind address: PF_ADDR/PF_HOST identify the participant. The URLs are
# opened from the browser running on the server itself (Guacamole), so there is
# no SSH tunnel involved.

set -euo pipefail

DIR=$(cd "$(dirname "$0")"; pwd -P)
. "$DIR/env.sh"

STATE_DIR="$HOME/.cache/otel-labs"
PID_FILE="$STATE_DIR/port-forward.pid"
LOG_FILE="$STATE_DIR/port-forward.log"

# What is forwarded: target, local port, port on the service, label.
# The review-service is missing until lab 2 deploys it, and that is fine: its
# supervisor keeps retrying and the access opens by itself.
FORWARDS="
svc/frontend-proxy              $UI_PORT     8080  UIs
svc/prometheus                  $PROM_PORT   9090  Prometheus
svc/$APP_NAME                   $APP_PORT    8080  $APP_NAME
svc/opensearch                  $OS_PORT     9200  OpenSearch
daemonset/otel-collector-agent  $ZPAGES_PORT 55679 zPages
"

usage() {
    cat << EOF
Usage: $(basename "$0") [-s] [-h]
Open the accesses used by the labs - demo UIs, Prometheus, $APP_NAME,
OpenSearch, collector zPages - and keep them open in the background.

  -s    stop them
  -h    this message
EOF
}

MODE=start
case "${1:-}" in
    "")      ;;
    -s)      MODE=stop ;;
    -h)      usage; exit 0 ;;
    --serve) MODE=serve ;;  # internal: the background supervisor
    *)       usage; exit 1 ;;
esac

# 'ss' tells us who holds a port and whether a forward is up; without it this
# script cannot do its job (package iproute2).
command -v ss > /dev/null || { echo "ERROR: 'ss' is required (iproute2)"; exit 1; }

# Free a port we are about to bind: a port-forward left running by a previous
# run - or started by hand - still holds PF_ADDR:port, and kubectl would stop
# on 'address already in use'. Only our own address is inspected, so a
# neighbour on the shared server is never touched, and only a kubectl process
# is ever killed.
free_port() {
    local port=$1 pid
    for pid in $(ss -lptnH "src $PF_ADDR:$port" 2> /dev/null \
                 | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u); do
        [ "$(ps -o comm= -p "$pid" 2> /dev/null)" = kubectl ] || continue
        kill "$pid" 2> /dev/null || true
    done
}

listening() {
    ss -ltnH "src $PF_ADDR:$1" 2> /dev/null | grep -q .
}

stop_all() {
    local pid target local_port remote_port label
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE")
        # negative PID: the whole process group, i.e. the supervisors and the
        # kubectl processes they started (see 'setsid' below)
        kill -TERM "-$pid" 2> /dev/null || kill -TERM "$pid" 2> /dev/null || true
        rm -f "$PID_FILE"
    fi
    while read -r target local_port remote_port label; do
        [ -n "$target" ] || continue
        free_port "$local_port"
    done <<< "$FORWARDS"
    sleep 1
}

# --- the background supervisor ----------------------------------------------
if [ "$MODE" = serve ]; then
    echo $$ > "$PID_FILE"
    while read -r target local_port remote_port label; do
        [ -n "$target" ] || continue
        (
            while true; do
                started=$SECONDS
                # '|| true': a failing kubectl must not kill the loop through
                # 'set -e' - failing is precisely what we recover from
                kubectl --namespace "$NS" port-forward --address "$PF_ADDR" \
                    "$target" "$local_port:$remote_port" || true
                # kubectl exited: bind again. This is what spares the labs the
                # 'restart your port-forward' step.
                echo "$(date '+%H:%M:%S') $label: reopening"
                if [ $((SECONDS - started)) -ge 5 ]; then
                    # the access was working and the pod got replaced (a
                    # redeploy): reopen at once, a lab is waiting for it
                    sleep 1
                else
                    # it failed straight away: the service is not deployed yet
                    # (review-service before lab 2), do not spin on it
                    sleep 5
                fi
            done
        ) &
    done <<< "$FORWARDS"
    wait
    exit 0
fi

if [ "$MODE" = stop ]; then
    stop_all
    echo "Accesses closed."
    exit 0
fi

# --- start ------------------------------------------------------------------
mkdir -p "$STATE_DIR"
stop_all  # a previous run, or a port-forward started by hand, holds the ports

: > "$LOG_FILE"
# setsid: the supervisor gets its own process group, so '-s' can take down the
# whole tree at once instead of leaving orphan port-forwards behind.
setsid "$0" --serve >> "$LOG_FILE" 2>&1 &

# The supervisor writes its own PID: with setsid it may not be the process
# started above, and that PID is what identifies the group to kill.
for _ in $(seq 1 20); do
    [ -f "$PID_FILE" ] && break
    sleep 0.5
done
if [ ! -f "$PID_FILE" ]; then
    echo "ERROR: the port-forwards did not start, see $LOG_FILE" >&2
    exit 1
fi

# Wait for the ports to answer before printing URLs that would 404.
pending=""
supervisor=$(cat "$PID_FILE")
for _ in $(seq 1 30); do
    pending=""
    # nothing left to wait for if the supervisor itself died
    kill -0 "$supervisor" 2> /dev/null || break
    while read -r target local_port remote_port label; do
        [ -n "$target" ] || continue
        listening "$local_port" || pending="$pending $label($local_port)"
    done <<< "$FORWARDS"
    [ -z "$pending" ] && break
    sleep 1
done

cat << EOF

Accesses are open (stop them with: scripts/$(basename "$0") -s)

  Astronomy Shop   http://$PF_HOST:$UI_PORT/
  Grafana          http://$PF_HOST:$UI_PORT/grafana/
  Jaeger           http://$PF_HOST:$UI_PORT/jaeger/ui/
  Load generator   http://$PF_HOST:$UI_PORT/loadgen/
  Feature flags    http://$PF_HOST:$UI_PORT/feature
  Prometheus       http://$PF_HOST:$PROM_PORT/
  $APP_NAME   http://$PF_HOST:$APP_PORT/
  OpenSearch       http://$PF_HOST:$OS_PORT/
  Collector zPages http://$PF_HOST:$ZPAGES_PORT/debug/pipelinez

They survive a redeploy: each access is reopened when its pod is replaced.
EOF

if [ -n "$pending" ]; then
    cat << EOF
Not answering yet:$pending
This is expected for $APP_NAME until you deploy it (lab 2); otherwise
check that the stack is up (kubectl get pods -n $NS) and read $LOG_FILE.
EOF
fi
echo
