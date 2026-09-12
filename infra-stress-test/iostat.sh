#!/bin/bash
# Débit et IOPS du disque racine sur 10 s, sans iostat.
D=${1:-sda}
r() { awk -v d="$D" '$3==d {print $4, $6, $8, $10, $13}' /proc/diskstats; }
read -r r1 rs1 w1 ws1 t1 <<< "$(r)"; sleep 10; read -r r2 rs2 w2 ws2 t2 <<< "$(r)"
awk -v r=$((r2-r1)) -v rs=$((rs2-rs1)) -v w=$((w2-w1)) -v ws=$((ws2-ws1)) -v t=$((t2-t1)) \
  'BEGIN{printf "%s: %.0f r/s + %.0f w/s = %.0f IOPS ; %.1f Mo/s lu, %.1f Mo/s écrit ; util %.0f %%\n", "'"$D"'", r/10, w/10, (r+w)/10, rs*512/10/1048576, ws*512/10/1048576, t/100}'
