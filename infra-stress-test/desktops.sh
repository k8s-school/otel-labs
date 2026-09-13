#!/bin/bash
# Anime les bureaux XFCE ouverts par Guacamole : un Firefox par participant sur
# un dashboard Grafana en rafraîchissement 5 s — ce qu'un stagiaire a sous les
# yeux pendant un lab, et ce que guacd doit encoder. En root sur le serveur.
#   ./desktops.sh start   # un Firefox par session XFCE vivante
#   ./desktops.sh stop
#   ./desktops.sh list    # sessions, DISPLAY, PSS par bureau
set -u
ACTION=${1:-list}
for pid in $(pgrep -x xfce4-session); do
    u=$(ps -o user= -p "$pid" | tr -d ' ')
    d=$(tr '\0' '\n' < "/proc/$pid/environ" | sed -n 's/^DISPLAY=//p')
    case "$ACTION" in
        list)
            pss=$(for p in $(pgrep -u "$u"); do awk '/^Pss:/{s+=$2} END{print s+0}' "/proc/$p/smaps_rollup" 2>/dev/null; done | awk '{s+=$1} END{printf "%.2f GiB", s/1048576}')
            ff=$(pgrep -u "$u" -c -f firefox)
            printf '%-10s DISPLAY=%-5s firefox=%-3s PSS=%s\n' "$u" "$d" "$ff" "$pss" ;;
        start)
            pf=$(sudo -u "$u" bash -lc '. ~/otel-labs/scripts/env.sh; echo $PF_HOST')   # pas -i : le shell de login expanserait $PF_HOST à vide
            url="http://$pf:8080/grafana/d/W2gX2zHVk48?refresh=5s&kiosk"
            sudo -u "$u" -i env DISPLAY="$d" nohup firefox --new-window "$url" > /dev/null 2>&1 &
            echo "$u : firefox sur $url (DISPLAY $d)" ;;
        stop) pkill -u "$u" -f firefox && echo "$u : firefox arrêté" ;;
    esac
done
