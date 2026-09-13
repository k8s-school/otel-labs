#!/bin/bash
# Simule 9 participants qui déroulent les labs en même temps. En root sur le serveur.
#   ./phase.sh up        # lab 1 : 9 × up.sh en parallèle (pic d'I/O), puis open-ui.sh
#   ./phase.sh deploy    # lab 2 : 9 × deploy.sh en parallèle (pic RAM/CPU : 9 JVM Maven)
#   ./phase.sh reviews   # lab 6 : 9 × generate-reviews.sh 600 (régime établi)
#   ./phase.sh lab8      # lab 8 : POST fautif + 30 GET/produit + requêtes Jaeger/OpenSearch, ×9
#   ./phase.sh openui    # (re)lance open-ui.sh pour chaque compte
#   ./phase.sh check     # état : clusters, pods, port-forwards, par compte
# Les logs vont dans /root/sim/log/<phase>-<user>.log, avec la durée en dernière ligne.
set -u
USERS=${USERS:-"trainer student1 student2 student3 student4 student5 student6 student7 student8"}
LOG=/root/sim/log; mkdir -p "$LOG"
PHASE=${1:?phase}

as_user() {   # as_user <user> <phase> : exécute /tmp/sim-<phase>.sh depuis ~/otel-labs, en login shell
    local u=$1 p=$2 t0
    t0=$(date +%s)
    sudo -u "$u" -i bash -l -c "cd ~/otel-labs && . /tmp/sim-$p.sh" > "$LOG/$p-$u.log" 2>&1
    echo "=== exit=$? duration=$(( $(date +%s) - t0 ))s" >> "$LOG/$p-$u.log"
}

run_all() {   # run_all <phase> <commandes> — les commandes passent par un fichier : sudo -i n'aime ni les
    local p=$1 cmd=$2 u                     # retours à la ligne ni les $ d'une commande multi-lignes
    printf '%s\n' "$cmd" > "/tmp/sim-$p.sh"; chmod 644 "/tmp/sim-$p.sh"
    echo "[$(date +%T)] $p : lancement sur $USERS"
    for u in $USERS; do as_user "$u" "$p" & done
    wait
    echo "[$(date +%T)] $p : terminé"
    for u in $USERS; do printf '  %-10s %s\n' "$u" "$(tail -1 "$LOG/$p-$u.log")"; done
}

case "$PHASE" in
    up)      run_all up "./scripts/up.sh && ./scripts/open-ui.sh" ;;
    deploy)  run_all deploy "./scripts/deploy.sh" ;;
    reviews) run_all reviews "./scripts/generate-reviews.sh 600 400" ;;
    lab8)    run_all lab8 '. ./scripts/env.sh
        for i in $(seq 5); do curl -s -o /dev/null -X POST http://$PF_HOST:$APP_PORT/api/reviews -H "Content-Type: application/json" -H "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.SECRET-JWT-TOKEN" -d "{\"productId\": \"DOESNOTEXIST\", \"rating\": 5, \"comment\": \"fuite\", \"userEmail\": \"leak@example.com\", \"userName\": \"Leaky User\"}"; done
        for i in $(seq 30); do curl -s -o /dev/null http://$PF_HOST:$APP_PORT/api/reviews/product/SECRET-PRODUCT-42; done
        n=0; until curl -s "http://$PF_HOST:$UI_PORT/jaeger/ui/api/traces?service=review-service&operation=SELECT%20otel&limit=20&lookback=1h" | grep -q SECRET-PRODUCT-42; do n=$((n+1)); [ $n -gt 24 ] && { echo "TIMEOUT jaeger"; break; }; sleep 5; done; echo "jaeger visible apres $((n*5))s"
        curl -s "http://$PF_HOST:$OS_PORT/otel-logs-*/_search?q=body:%22leak@example.com%22&size=0" | grep -o "\"total\":{[^}]*}"' ;;
    check)
        cat > /tmp/sim-check-user.sh <<'CHK'
. ~/otel-labs/scripts/env.sh 2>/dev/null
ctx=$(kubectl config current-context 2>/dev/null)
all=$(kubectl get pods -n otel-demo --no-headers 2>/dev/null | wc -l)
ready=$(kubectl get pods -n otel-demo --no-headers 2>/dev/null | grep -c "Running\|Completed")
pf=$(ss -ltnH "src $PF_ADDR" 2>/dev/null | wc -l)
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://$PF_HOST:8080/grafana/api/health")
echo "ctx=$ctx pods=$ready/$all port-forwards=$pf grafana=$code"
CHK
        chmod 644 /tmp/sim-check-user.sh
        for u in $USERS; do printf '%-10s ' "$u"; timeout 60 sudo -u "$u" -i bash -l /tmp/sim-check-user.sh; done ;;
    openui)  run_all openui "./scripts/open-ui.sh" ;;
    *) echo "phase inconnue : $PHASE"; exit 1 ;;
esac
