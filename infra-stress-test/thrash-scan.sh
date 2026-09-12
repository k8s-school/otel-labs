#!/bin/bash
# Trouve les conteneurs qui « thrashent » : collés à leur limite mémoire, ils
# relisent en boucle depuis le disque les pages que le cgroup vient d'évincer.
# C'est ce qui a saturé le volume du GP1-L (accounting, puis checkout) alors que
# la machine avait 70 Gio de libre. Mesure sur 10 s, en root.
#   ./thrash-scan.sh          # les conteneurs à > 90 % de leur limite, avec refaults/s
#   ./thrash-scan.sh 50       # autre seuil (%)
set -u
export LC_ALL=C
SEUIL=${1:-90}
declare -A before name
for cg in $(find /sys/fs/cgroup -path '*kubepods*' -name 'cri-containerd-*.scope' -type d 2>/dev/null); do
    max=$(cat "$cg/memory.max" 2>/dev/null); [ "$max" = max ] && continue; [ -z "$max" ] && continue
    cur=$(cat "$cg/memory.current"); [ $((cur * 100 / max)) -ge "$SEUIL" ] || continue
    before[$cg]=$(awk '/^workingset_refault_file/ {print $2}' "$cg/memory.stat")
    pid=$(head -1 "$cg/cgroup.procs" 2>/dev/null)
    name[$cg]="$(tr '\0' ' ' < "/proc/${pid:-0}/cmdline" 2>/dev/null | cut -c1-40)"
done
sleep 10
printf '%-42s %8s %8s %12s\n' CONTENEUR 'Mio' 'max' 'refaults/s'
for cg in "${!before[@]}"; do
    after=$(awk '/^workingset_refault_file/ {print $2}' "$cg/memory.stat")
    rate=$(( (after - before[$cg]) / 10 ))
    printf '%-42s %8d %8d %12d %s\n' "${name[$cg]}" $(( $(cat "$cg/memory.current") / 1048576 )) $(( $(cat "$cg/memory.max") / 1048576 )) "$rate" "$([ $rate -gt 1000 ] && echo '<-- THRASH')"
done | sort -k4 -rn
