#!/bin/bash
# Applique aux 9 clusters les limites mémoire de manifests/values-training.yaml
# sans attendre un up.sh : un `kubectl set resources` par compte et par service.
# À lancer en root sur le serveur après avoir relevé une limite dans le values.
#   ./apply-limits.sh                       # accounting et checkout, valeurs du values
#   ./apply-limits.sh currency 20Mi 64Mi    # un service, requête, limite
#   ./apply-limits.sh flagd 75Mi 200Mi flagd # idem, un seul conteneur du pod
set -u
export LC_ALL=C
USERS=${USERS:-"trainer student1 student2 student3 student4 student5 student6 student7 student8"}
apply() {   # apply <deploy> <request> <limit> [conteneur] — sans conteneur, tous ceux du pod
    local c=${4:+-c $4}
    for u in $USERS; do
        printf '%-10s %-12s ' "$u" "$1"
        timeout 60 sudo -u "$u" -i kubectl -n otel-demo set resources deploy "$1" $c --requests=memory="$2" --limits=memory="$3" 2>&1 | tail -1 | cut -c1-70
    done
}
if [ $# -ge 3 ]; then apply "$@"; else
    apply accounting      120Mi 300Mi
    apply checkout        20Mi  100Mi
    apply product-catalog 20Mi  96Mi
    apply shipping        20Mi  96Mi
    apply currency        20Mi  96Mi
    apply frontend-proxy  65Mi  200Mi
    apply flagd           75Mi  200Mi flagd   # pas le sidecar flagd-ui (250Mi)
fi
