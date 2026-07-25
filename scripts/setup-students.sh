#!/bin/bash

# Trainer script: provision N participant accounts on a shared server.
# Each participant gets a Unix account, a dedicated kind cluster and a
# PORT_OFFSET so port-forwards never collide: student<N> uses the offset N,
# hence the demo UI on 808<N> (student3 -> 8083).
#
# The demo images are pulled once on the host then loaded into every
# participant cluster, so the classroom does not download them N times.
# The OpenTelemetry stack itself is NOT installed: participants do it in
# lab 1 with 'scripts/up.sh'.
#
# Run as root on the shared server (docker, kind >= 0.27, ktbx, helm,
# kubectl installed system-wide).
#
# Usage: setup-students.sh [count]   (default: 9, max 9)

set -euo pipefail

COUNT="${1:-9}"
REPO_URL="https://github.com/k8s-school/otel-labs.git"

DIR=$(cd "$(dirname "$0")"; pwd -P)

[ "$(id -u)" = 0 ] || { echo "ERROR: run as root"; exit 1; }

# Above 9 the 808<N> convention breaks down: student10 would take 8090, which
# is student0's review-service port. More participants => switch to a wider
# offset (N*100) in env.sh and in the .bashrc written below.
[ "$COUNT" -le 9 ] || { echo "ERROR: at most 9 participants (808<N> port convention)"; exit 1; }

for i in $(seq 1 "$COUNT"); do
    student="student$i"
    offset=$i

    # 1. Unix account, member of the docker group
    id "$student" > /dev/null 2>&1 || useradd -m -s /bin/bash -G docker "$student"

    # 2. Training environment: own cluster name + port offset
    if ! grep -q "OTEL_TRAINING" "/home/$student/.bashrc" 2>/dev/null; then
        cat >> "/home/$student/.bashrc" << EOF

# OTEL_TRAINING environment
export CLUSTER_NAME=$student
export PORT_OFFSET=$offset
EOF
    fi

    # 3. Clone the training repository
    if [ ! -d "/home/$student/otel-labs" ]; then
        sudo -u "$student" git clone "$REPO_URL" "/home/$student/otel-labs"
    fi

    # 4. Create the participant's kind cluster (single node) and hand the
    #    kubeconfig over to the student account
    if ! kind get clusters 2>/dev/null | grep -qx "$student"; then
        ktbx create -s -n "$student"
    fi
    sudo -u "$student" mkdir -p "/home/$student/.kube"
    kind get kubeconfig --name "$student" > "/home/$student/.kube/config"
    chown "$student:$student" "/home/$student/.kube/config"
    chmod 600 "/home/$student/.kube/config"

    # 5. Preload the demo images into that cluster (host cache is shared:
    #    only the first participant actually downloads them)
    "$DIR/preload-images.sh" -n "$student"

    echo "--- $student ready (cluster: $student, ports: UI $((8080 + offset)) / app $((8090 + offset)))"
done

echo
echo "$COUNT participants provisioned (images preloaded, OTel stack not installed)."
echo "Each student: ssh student<N>@<server>, then: cd otel-labs && ./scripts/up.sh"
echo "UIs via SSH tunnel, e.g.: ssh -L 8081:localhost:8081 student1@<server>"
