#!/usr/bin/env bash
set -e
YAML=$1
STAMP=$(date +%F-%H%M)
OUT=reports/$STAMP; mkdir -p "$OUT"

# (re)build & load SELinux module
python selinux/gen_policy.py artefacts/rules.json
sudo semodule -i selinux/encryption_control.pp

# restart daemons; their stdin sockets are /run/rule_pipe, /run/model_pipe
sudo systemctl restart rule_daemon
sudo systemctl restart model_daemon

echo "cmd,label" > "$OUT/meta.csv"
yq -o=json '.[]' "$YAML" | while read -r row; do
  cmd=$(echo "$row"|jq -r .cmd); lab=$(echo "$row"|jq -r .label)
  echo "$cmd,$lab" >> "$OUT/meta.csv"
  eval "$cmd" & pid=$!
  echo $pid | sudo tee /run/rule_daemon.stdin   >/dev/null
  echo $pid | sudo tee /run/model_daemon.stdin  >/dev/null
  wait $pid
done

sudo cp /var/log/audit/audit.log "$OUT/selinux_audit.log"
sudo systemctl stop rule_daemon model_daemon
cp daemon/evidence/*decisions.csv "$OUT/"

python experiments/evaluate.py "$OUT"

