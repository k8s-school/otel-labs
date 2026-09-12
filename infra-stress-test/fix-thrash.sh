#!/bin/bash
# Remède d'urgence au thrashing d'un service de la démo, quand les API servers
# ne répondent plus et que kubectl est inutilisable.
#
# Constat (GP1-L, 9 stacks, 2026-09-12) : un pod collé à sa limite mémoire
# (accounting à 120 Mi, checkout à 20 Mi — les valeurs du chart) voit le cgroup
# évincer en boucle les pages de son binaire, qu'il relit depuis le disque à
# 100-375 Mo/s. Neuf pods suffisent à saturer un volume sbs_5k et à rendre les
# 9 API servers injoignables. Repérage : ./thrash-scan.sh.
#
# Ce script relève memory.max des cgroups en place (effet immédiat, sans passer
# par Kubernetes). Le remède durable est la limite dans
# manifests/values-training.yaml, appliquée par up.sh ou par ./apply-limits.sh.
#   ./fix-thrash.sh "dotnet Accounting.dll" 300M
#   ./fix-thrash.sh "^./checkout" 100M
set -u
export LC_ALL=C
PATTERN=${1:?motif pgrep -f}
LIMIT=${2:?limite, ex. 300M}
bytes=$(numfmt --from=iec "$LIMIT")
n=0
for p in $(pgrep -f "$PATTERN"); do
    cg=/sys/fs/cgroup$(cut -d: -f3 "/proc/$p/cgroup")
    [ -f "$cg/memory.max" ] || continue
    echo "$bytes" > "$cg/memory.max" && n=$((n+1))
done
echo "$(date +%T) memory.max relevé à $LIMIT sur $n conteneurs « $PATTERN »"
echo "avant : $(cut -d' ' -f1-3 /proc/loadavg) ; $(grep some /proc/pressure/io)"
sleep 60
echo "après : $(cut -d' ' -f1-3 /proc/loadavg) ; $(grep some /proc/pressure/io)"
"$(dirname "$0")/iostat.sh"
