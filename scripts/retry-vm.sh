#!/usr/bin/env bash
# Contorna o "Out of host capacity" da Ampere A1 repetindo o terraform apply do infra/
# até a VM ser criada (ocpus/memory_gb do infra/terraform.tfvars; free tier: 2 OCPU / 12 GB).
#
# Rodar desacoplado do terminal (sobrevive ao fechar a sessão):
#   nohup setsid scripts/retry-vm.sh > retry.log 2>&1 &
#   tail -f retry.log
#
# Ajustes por variável de ambiente (valores padrão entre parênteses):
#   TRIES (2880)  SLEEP (60)  -> ~48 h
cd "$(dirname "$0")/../infra" || exit 1

TRIES=${TRIES:-2880} SLEEP=${SLEEP:-60}

for i in $(seq 1 "$TRIES"); do
  echo "== tentativa $i $(date +%T)"
  out=$(terraform apply -no-color -auto-approve 2>&1)
  if echo "$out" | grep -q "Apply complete"; then
    echo "$out" | grep -A5 '^Outputs:'
    echo "OK"
    exit 0
  fi
  echo "$out" | grep -oE 'Error: [^,]*,[^.(]*' | head -1
  sleep "$SLEEP"
done
echo "FALHOU: sem capacidade depois de $TRIES tentativas"
exit 1
