#!/bin/bash

# Trainer script: provision N participant accounts on a shared server.
# Each participant gets a Unix account, a dedicated kind cluster and a
# PORT_OFFSET so port-forwards never collide.
#
# Run as root on the shared server (docker, kind >= 0.27, ktbx, helm,
# kubectl installed system-wide).
#
# Usage: setup-students.sh [count]   (default: 10)

set -euo pipefail

COUNT="${1:-10}"
REPO_URL="https://github.com/k8s-school/otel.git"

[ "$(id -u)" = 0 ] || { echo "ERROR: run as root"; exit 1; }

for i in $(seq 1 "$COUNT"); do
    student="student$i"
    offset=$((i * 100))

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
    if [ ! -d "/home/$student/otel" ]; then
        sudo -u "$student" git clone "$REPO_URL" "/home/$student/otel"
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

    echo "--- $student ready (cluster: $student, ports: UI $((8080 + offset)) / app $((8090 + offset)))"
done

echo
echo "$COUNT participants provisioned."
echo "Each student: ssh student<N>@<server>, then: cd otel && ./scripts/up.sh"
echo "UIs via SSH tunnel, e.g.: ssh -L 8180:localhost:8180 student1@<server>"
