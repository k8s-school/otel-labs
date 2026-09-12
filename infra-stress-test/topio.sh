#!/bin/bash
# Les 15 processus qui lisent/écrivent le plus sur le disque pendant 10 s (read_bytes/write_bytes de /proc/<pid>/io = vrais accès disque, pas le cache).
snap() { for p in /proc/[0-9]*; do awk -v p="${p#/proc/}" '/^read_bytes/{r=$2} /^write_bytes/{w=$2} END{print p, r+0, w+0}' "$p/io" 2>/dev/null; done; }
snap | sort > /tmp/io1; sleep 10; snap | sort > /tmp/io2
join /tmp/io1 /tmp/io2 | awk '{r=$4-$2; w=$5-$3; if (r+w>0) print r/10/1048576, w/10/1048576, $1}' | sort -rn | head -15 | while read -r r w pid; do
    printf '%7.1f Mo/s lu %7.1f Mo/s écrit  pid=%-7s %s\n' "$r" "$w" "$pid" "$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null | cut -c1-90)"
done
