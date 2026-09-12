#!/bin/bash
# Limites de l'hôte Linux, usage courant contre plafond. En root, une fois les
# 9 stacks et les 9 bureaux en place — c'est là que ça compte.
set -u
export LC_ALL=C
row() { printf '  %-28s %12s / %-12s %s\n' "$1" "$2" "$3" "$4"; }
pct() { awk -v a="$1" -v b="$2" 'BEGIN{ if (b>0) printf "%.0f %%", 100*a/b; else print "-" }'; }
echo "=== Limites noyau ==="
ino=$(find /proc/[0-9]*/fd -lname 'anon_inode:inotify' 2>/dev/null | wc -l)
ino_max=$(( $(cat /proc/sys/fs/inotify/max_user_instances) ))
row "inotify instances (root)" "$ino" "$ino_max" "$(pct "$ino" "$ino_max")"
thr=$(ps -eo nlwp= | awk '{s+=$1} END{print s}'); thr_max=$(cat /proc/sys/kernel/threads-max)
row "threads" "$thr" "$thr_max" "$(pct "$thr" "$thr_max")"
pids=$(ls -d /proc/[0-9]* | wc -l); pid_max=$(cat /proc/sys/kernel/pid_max)
row "processus" "$pids" "$pid_max" "$(pct "$pids" "$pid_max")"
ct=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0); ct_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 0)
row "conntrack" "$ct" "$ct_max" "$(pct "$ct" "$ct_max")"
read -r fo _ fmax < /proc/sys/fs/file-nr
row "fichiers ouverts" "$fo" "$fmax" "$(pct "$fo" "$fmax")"
keys=$(awk -F'[ :/]+' '$1=="0" {print $4}' /proc/key-users 2>/dev/null | head -1); keys_max=$(cat /proc/sys/kernel/keys/maxkeys)
row "clés keyring (root)" "${keys:-?}" "$keys_max" "$(pct "${keys:-0}" "$keys_max")"
cg=$(find /sys/fs/cgroup -type d 2>/dev/null | wc -l)
row "cgroups" "$cg" "-" ""
lo=$(ip -4 addr show lo | grep -c 'inet 127')
row "adresses 127.x sur lo" "$lo" "-" "(une par participant, PF_ADDR)"
echo
echo "=== Docker ==="
row "conteneurs" "$(docker ps -q | wc -l)" "-" "($(docker ps -q --filter name=control-plane | wc -l) nœuds kind)"
row "volumes" "$(docker volume ls -q | wc -l)" "-" ""
vol=$(du -sh /var/lib/docker/volumes 2>/dev/null | cut -f1)
row "taille des volumes" "$vol" "-" "(image stores des nœuds kind)"
row "images hôte" "$(docker images -q | wc -l)" "-" "$(docker system df --format '{{.Size}}' | head -1)"
echo
echo "=== Disque ==="
df -h --output=target,size,used,avail,pcent / /var/lib/docker 2>/dev/null | sort -u
echo
echo "=== Mémoire ==="
awk '/MemTotal|MemAvailable|SwapTotal|SwapFree|Dirty:|Shmem:/ {printf "  %-16s %6.1f GiB\n", $1, $2/1048576}' /proc/meminfo
echo "  PSI memory : $(cat /proc/pressure/memory | tr '\n' ' ')"
echo "  PSI io     : $(cat /proc/pressure/io | tr '\n' ' ')"
echo "  PSI cpu    : $(cat /proc/pressure/cpu | tr '\n' ' ')"
echo
echo "=== OOM kills depuis le boot ==="
dmesg -T 2>/dev/null | grep -ci "killed process" || journalctl -k --no-pager 2>/dev/null | grep -ci "killed process"
