#!/bin/bash
# Pose des avis pendant DURATION secondes : une rafale au démarrage, puis un
# rythme qui se relâche peu à peu. Donne aux métriques de ce lab une courbe
# à observer plutôt qu'un débit constant.
DIR=$(cd "$(dirname "$0")"; pwd -P)
. "$DIR/env.sh"

DURATION=${1:-600}
MAX=${2:-400}          # plafond : ces avis restent en base
PRODUCTS=(OLJCESPC7Z 0PUK6V6EV0 1YMWWN1N4O 2ZYFJ3GM2N 66VCHSJNUP)
START=$SECONDS
END=$((START + DURATION))
NEXT_REPORT=$((START + 60))
created=0
failed=0

while [ "$SECONDS" -lt "$END" ] && [ "$((created + failed))" -lt "$MAX" ]; do
    rating=$((RANDOM % 5 + 1))
    product=${PRODUCTS[$((RANDOM % ${#PRODUCTS[@]}))]}
    n=$((created + failed + 1))
    code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
        "http://$PF_HOST:$APP_PORT/api/reviews" \
        -H "Content-Type: application/json" \
        -d "{\"productId\": \"$product\", \"rating\": $rating, \"comment\": \"lab6\",
             \"userEmail\": \"user$n@example.com\", \"userName\": \"User $n\"}")
    if [ "$code" = "201" ]; then created=$((created + 1)); else failed=$((failed + 1)); fi

    if [ "$SECONDS" -ge "$NEXT_REPORT" ]; then
        printf '%s  %d avis créés, %d échecs, %d s restantes\n' \
            "$(date +%H:%M:%S)" "$created" "$failed" "$((END - SECONDS))"
        NEXT_REPORT=$((SECONDS + 60))
    fi

    # Cadence : ~7 avis/s pendant les 15 premières secondes, puis un intervalle
    # qui s'allonge avec le temps écoulé, jusqu'à un avis toutes les 8 s.
    elapsed=$((SECONDS - START))
    if [ "$elapsed" -lt 15 ]; then
        sleep 0.15
    else
        delay=$((elapsed / 40))
        [ "$delay" -lt 1 ] && delay=1
        [ "$delay" -gt 8 ] && delay=8
        sleep "$delay"
    fi
done

printf 'Terminé : %d avis créés, %d échecs.\n' "$created" "$failed"
