#!/bin/bash
# Comme fix-thrash.sh, mais relève AUSSI la limite du cgroup de pod parent :
# quand un pod n'a qu'un conteneur applicatif, le chart pose souvent la limite
# au niveau du pod (kubelet-kubepods-...-pod<uid>.slice), et relever le seul
# conteneur ne sert à rien — le pod plafonne au-dessus. Cas de frontend-proxy
# (envoy), plafonné à 65 Mi côté pod.
#   ./fix-pod-thrash.sh "^envoy -c" 250M
set -u
export LC_ALL=C
PATTERN=${1:?motif pgrep -f}; LIMIT=${2:?limite}
bytes=$(numfmt --from=iec "$LIMIT"); n=0
for p in $(pgrep -f "$PATTERN"); do
    cg=/sys/fs/cgroup$(cut -d: -f3 "/proc/$p/cgroup")
    # conteneur, puis pod parent (…-pod<uid>.slice)
    [ -f "$cg/memory.max" ] && echo "$bytes" > "$cg/memory.max"
    pod=$(dirname "$cg")
    case "$pod" in *pod*.slice) [ -f "$pod/memory.max" ] && echo "$bytes" > "$pod/memory.max" && n=$((n+1)) ;; esac
done
echo "$(date +%T) $n pods « $PATTERN » relevés à $LIMIT (conteneur + slice de pod)"
