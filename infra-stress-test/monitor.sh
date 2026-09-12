#!/bin/bash
# Échantillonne la machine toutes les 13 s (pas un diviseur du cycle de 40 s de
# la stack, cf. NOTE-dimensionnement-serveur.md) dans un CSV. Lancer en root :
#   nohup ./monitor.sh /root/sim/monitor.csv &
set -u
OUT=${1:-/root/sim/monitor.csv}
INTERVAL=13
echo "ts,load1,mem_used_gib,mem_avail_gib,swap_used_mib,cpu_idle_pct,io_wait_pct,disk_used_gb,psi_cpu_some10,psi_mem_some10,psi_mem_full10,psi_io_some10,psi_io_full10,conntrack,inotify_inst,threads,containers,xfce_sessions" > "$OUT"
prev_idle=0; prev_total=0; prev_iow=0
while true; do
    read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
    total=$((user+nice+system+idle+iowait+irq+softirq+steal))
    d_total=$((total-prev_total)); d_idle=$((idle-prev_idle)); d_iow=$((iowait-prev_iow))
    if [ "$d_total" -gt 0 ]; then
        idle_pct=$(awk -v a="$d_idle" -v b="$d_total" 'BEGIN{printf "%.1f", 100*a/b}')
        iow_pct=$(awk -v a="$d_iow" -v b="$d_total" 'BEGIN{printf "%.1f", 100*a/b}')
    else idle_pct=""; iow_pct=""; fi
    prev_idle=$idle; prev_total=$total; prev_iow=$iowait
    mem=$(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} /SwapTotal/{st=$2} /SwapFree/{sf=$2} END{printf "%.2f,%.2f,%.0f", (t-a)/1048576, a/1048576, (st-sf)/1024}' /proc/meminfo)
    psi() { awk -v k="$2" '$1==k {for(i=2;i<=NF;i++) if ($i ~ /^avg10=/) {sub("avg10=","",$i); print $i}}' "/proc/pressure/$1" 2>/dev/null || echo ""; }
    ct=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "")
    ino=$(find /proc/[0-9]*/fd -lname 'anon_inode:inotify' 2>/dev/null | wc -l)
    thr=$(awk '{print $1}' /proc/loadavg >/dev/null; cat /proc/sys/kernel/threads-max >/dev/null; ps -eo nlwp= | awk '{s+=$1} END{print s}')
    ctn=$(docker ps -q 2>/dev/null | wc -l)
    xs=$(pgrep -cx xfce4-session)
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(date +%FT%T)" "$(cut -d' ' -f1 /proc/loadavg)" "$mem" "$idle_pct" "$iow_pct" \
        "$(df --output=used -BG / | tail -1 | tr -dc 0-9)" \
        "$(psi cpu some)" "$(psi memory some)" "$(psi memory full)" "$(psi io some)" "$(psi io full)" \
        "$ct" "$ino" "$thr" "$ctn" "$xs" >> "$OUT"
    sleep "$INTERVAL"
done
