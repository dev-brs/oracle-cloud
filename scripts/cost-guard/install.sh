#!/usr/bin/env bash
# Instala (ou atualiza) na VM o timer que roda oci-cost.py guard a cada hora.
# Uso: scripts/cost-guard/install.sh   (VM_HOST=ubuntu@<ip> e VM_KEY=<chave> sobrescrevem o padrão)
# Requer o dynamic group e a policy de bootstrap/cost_guard.tf.
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
if [[ -z ${VM_HOST:-} ]]; then
  IP=$(terraform -chdir="$DIR/../../infra" output -raw public_ip) \
    || { echo "Não consegui ler o IP do Terraform; defina VM_HOST=ubuntu@<ip>."; exit 1; }
  VM_HOST=ubuntu@$IP
fi
KEY=${VM_KEY:-$(terraform -chdir="$DIR/../../infra" output -raw ssh_command | sed -E 's/^ssh -i ([^ ]+) .*/\1/')}
KEY=${KEY/#\~/$HOME}

scp -i "$KEY" "$DIR/../oci-cost.py" "$DIR/cost-guard.service" "$DIR/cost-guard.timer" "$VM_HOST:/tmp/"
ssh -i "$KEY" "$VM_HOST" 'set -e
  sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-venv >/dev/null
  sudo mkdir -p /opt/cost-guard
  [[ -x /opt/cost-guard/venv/bin/python ]] || sudo python3 -m venv /opt/cost-guard/venv
  sudo /opt/cost-guard/venv/bin/pip install -q --upgrade oci
  sudo install -m 755 /tmp/oci-cost.py /opt/cost-guard/oci-cost.py
  sudo install -m 644 /tmp/cost-guard.service /tmp/cost-guard.timer /etc/systemd/system/
  rm /tmp/oci-cost.py /tmp/cost-guard.service /tmp/cost-guard.timer
  sudo systemctl daemon-reload
  sudo systemctl enable --now cost-guard.timer
  sudo /opt/cost-guard/venv/bin/python /opt/cost-guard/oci-cost.py guard --auth instance_principal --dry-run
  systemctl list-timers cost-guard.timer --no-pager'
