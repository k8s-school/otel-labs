#!/bin/bash
# Stress tests complémentaires, à lancer en root une fois les 9 stacks en régime.
# Chacun cherche une marge, pas un record : la question est « la salle survit-elle ? ».
#   ./stress.sh io        # fio sur le volume racine : IOPS/latence, c'est ce que voient 9 kind load
#   ./stress.sh mem       # stress-ng mange 80 % de la RAM disponible 3 min : les stacks tiennent ?
#   ./stress.sh cpu       # stress-ng sature tous les vCPU 3 min : latence des UIs pendant ce temps ?
#   ./stress.sh rebuild   # 9 × deploy.sh ×2 d'affilée : croissance disque des image stores
#   ./stress.sh probe     # latence Grafana/Jaeger/review-service pour les 9 comptes, à lancer PENDANT un autre test
set -u
USERS=${USERS:-"trainer student1 student2 student3 student4 student5 student6 student7 student8"}
LOG=/root/sim/log; mkdir -p "$LOG"
need() { command -v "$1" > /dev/null || { apt-get install -y -q "$1" > /dev/null 2>&1 || { echo "impossible d'installer $1"; exit 1; }; }; }
case "${1:?test}" in
    io)
        need fio
        echo "[$(date +%T)] fio : 4k aléatoire, 70/30 lecture/écriture, 60 s, profondeur 32"
        fio --name=kindload --directory=/var/lib/docker --size=4G --rw=randrw --rwmixread=70 --bs=4k --iodepth=32 --ioengine=libaio --direct=1 --runtime=60 --time_based --group_reporting --output-format=terse 2>/dev/null \
          | awk -F';' '{printf "  lecture %s IOPS (lat p99 %.1f ms) / écriture %s IOPS (lat p99 %.1f ms)\n", $8, $30/1000, $49, $71/1000}'
        rm -f /var/lib/docker/kindload*
        echo "[$(date +%T)] fio : séquentiel 1M écriture 30 s (le profil d'un kind load)"
        fio --name=seqw --directory=/var/lib/docker --size=4G --rw=write --bs=1M --iodepth=8 --ioengine=libaio --direct=1 --runtime=30 --time_based --group_reporting --output-format=terse 2>/dev/null \
          | awk -F';' '{printf "  écriture %.0f Mo/s\n", $48/1024}'
        rm -f /var/lib/docker/seqw* ;;
    mem)
        need stress-ng
        avail=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)
        take=$((avail * 80 / 100))
        echo "[$(date +%T)] stress-ng : ${take} Mio sur ${avail} disponibles, 180 s — surveiller PSI memory et OOM"
        before=$(dmesg 2>/dev/null | grep -ci "killed process")
        stress-ng --vm 4 --vm-bytes "${take}M" --vm-keep --timeout 180s --metrics-brief 2>&1 | tail -3
        after=$(dmesg 2>/dev/null | grep -ci "killed process")
        echo "  OOM kills pendant le test : $((after - before))"
        echo "  PSI memory : $(cat /proc/pressure/memory | tr '\n' ' ')" ;;
    cpu)
        need stress-ng
        echo "[$(date +%T)] stress-ng : $(nproc) workers CPU, 180 s — lancer ./stress.sh probe à côté"
        stress-ng --cpu "$(nproc)" --timeout 180s --metrics-brief 2>&1 | tail -2 ;;
    rebuild)
        before=$(du -sm /var/lib/docker/volumes 2>/dev/null | cut -f1)
        for round in 1 2; do
            echo "[$(date +%T)] rebuild $round/2 : 9 × deploy.sh"
            for u in $USERS; do sudo -u "$u" -i bash -lc 'cd ~/otel-labs && ./scripts/deploy.sh' > "$LOG/rebuild$round-$u.log" 2>&1 & done; wait
            after=$(du -sm /var/lib/docker/volumes 2>/dev/null | cut -f1)
            echo "  volumes : $before Mio -> $after Mio (+$(( (after - before) / 9 )) Mio par participant)"
        done ;;
    probe)
        cat > /tmp/sim-probe-user.sh <<'PRB'
. ~/otel-labs/scripts/env.sh 2>/dev/null
t() { curl -s -o /dev/null -w "%{time_total}" --max-time 20 "$1" 2>/dev/null || echo "-"; }
printf '  %-10s %8s %8s %8s\n' "$USER" "$(t http://$PF_HOST:8080/grafana/api/health)" "$(t http://$PF_HOST:8080/jaeger/ui/api/services)" "$(t http://$PF_HOST:$APP_PORT/api/reviews)"
PRB
        chmod 644 /tmp/sim-probe-user.sh
        printf '  %-10s %8s %8s %8s\n' USER grafana jaeger reviews
        for u in $USERS; do timeout 60 sudo -u "$u" -i bash -l /tmp/sim-probe-user.sh & done; wait ;;
    *) echo "test inconnu"; exit 1 ;;
esac
