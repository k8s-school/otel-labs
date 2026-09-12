#!/bin/bash
# Suit la convergence des 9 stacks : load, IOPS, PSI io, pods prêts par compte. Une ligne par minute.
USERS=${USERS:-"trainer student1 student2 student3 student4 student5 student6 student7 student8"}
while true; do
    io=$(/root/sim/iostat.sh | grep -o "[0-9]* IOPS")
    psi=$(awk '/some/ {for(i=2;i<=NF;i++) if ($i ~ /^avg60=/) {sub("avg60=","",$i); print $i}}' /proc/pressure/io)
    pods=""
    for u in $USERS; do
        r=$(timeout 20 sudo -u "$u" -i kubectl get pods -n otel-demo --no-headers 2>/dev/null | awk '/Running|Completed/{r++} END{print r+0}')
        pods="$pods $r"
    done
    echo "$(date +%T) load=$(cut -d' ' -f1 /proc/loadavg) $io psi_io60=$psi ready:$pods"
    sleep 50
done
