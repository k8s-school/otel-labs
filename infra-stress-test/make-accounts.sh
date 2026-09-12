#!/bin/bash
# Écrit accounts.txt (« user password » par ligne) pour guac-load.py, à partir du
# vault Ansible, sans rien afficher. Règle : studentN -> "<N><participant_password>",
# trainer -> trainer_password.
set -euo pipefail
A=$(cd "$(dirname "$0")/../../../../../../home/fjammes/src/github.com/k8s-school/k8s-server/provisioning/ansible" 2>/dev/null && pwd || echo /home/fjammes/src/github.com/k8s-school/k8s-server/provisioning/ansible)
OUT=$(dirname "$0")/accounts.txt
N=${1:-8}
ansible-vault view --vault-password-file "$A/.vault-pass" "$A/group_vars/all/vault.yml" \
  | python3 -c "
import sys, yaml
v = yaml.safe_load(sys.stdin)
out = open('$OUT', 'w')
out.write('trainer %s\n' % v['vault_trainer_password'])
for i in range(1, $N + 1):
    out.write('student%d %d%s\n' % (i, i, v['vault_participant_password']))
"
chmod 600 "$OUT"
echo "$(wc -l < "$OUT") comptes écrits dans $OUT"
