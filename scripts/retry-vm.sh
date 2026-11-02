#!/usr/bin/env bash
# Contorna o "Out of host capacity" da Ampere A1 repetindo o terraform apply do infra/.
# Fase 1: cria a VM pequena (2 OCPU / 12 GB), que encontra capacidade mais fácil.
# Fase 2: com a VM criada, tenta redimensionar para o máximo do free tier (4 OCPU / 24 GB).
#         Cada tentativa de redimensionar REINICIA a VM, mesmo quando falha.
# Se a fase 2 der certo, ocpus e memory_gb do infra/terraform.tfvars passam para 4 / 24.
#
# Rodar desacoplado do terminal (sobrevive ao fechar a sessão):
#   nohup setsid scripts/retry-vm.sh > retry.log 2>&1 &
#   tail -f retry.log
#
# Ajustes por variável de ambiente (valores padrão entre parênteses):
#   SMALL_OCPUS (2)  SMALL_MEM (12)  SMALL_TRIES (2880)  SMALL_SLEEP (60)  -> fase 1, ~48 h
#   BIG_OCPUS   (4)  BIG_MEM   (24)  BIG_TRIES   (480)   BIG_SLEEP   (30)  -> fase 2, ~4 h
#   SKIP_PHASE1=1  pula direto para o redimensionamento (VM já existe com 2/12).
cd "$(dirname "$0")/../infra" || exit 1

SMALL_OCPUS=${SMALL_OCPUS:-2} SMALL_MEM=${SMALL_MEM:-12}
SMALL_TRIES=${SMALL_TRIES:-2880} SMALL_SLEEP=${SMALL_SLEEP:-60}
BIG_OCPUS=${BIG_OCPUS:-4} BIG_MEM=${BIG_MEM:-24}
BIG_TRIES=${BIG_TRIES:-480} BIG_SLEEP=${BIG_SLEEP:-30}

try() { # $1=ocpus $2=mem $3=max $4=intervalo
  for i in $(seq 1 "$3"); do
    echo "== $1 OCPU/$2 GB tentativa $i $(date +%T)"
    out=$(terraform apply -no-color -auto-approve -var ocpus="$1" -var memory_gb="$2" 2>&1)
    if echo "$out" | grep -q "Apply complete"; then echo "$out" | grep -A5 '^Outputs:'; return 0; fi
    echo "$out" | grep -oE 'Error: [^,]*,[^.(]*' | head -1
    sleep "$4"
  done
  return 1
}

if [[ -z ${SKIP_PHASE1:-} ]]; then
  try "$SMALL_OCPUS" "$SMALL_MEM" "$SMALL_TRIES" "$SMALL_SLEEP" || { echo "FASE1 FALHOU"; exit 1; }
  echo "FASE1 OK"
fi
if try "$BIG_OCPUS" "$BIG_MEM" "$BIG_TRIES" "$BIG_SLEEP"; then
  sed -i -E "s/^(#\s*)?ocpus(\s*)=.*/ocpus\2= $BIG_OCPUS/; s/^(#\s*)?memory_gb(\s*)=.*/memory_gb\2= $BIG_MEM/" terraform.tfvars
  echo "FASE2 OK"
else
  echo "FASE2 sem capacidade; VM segue com $SMALL_OCPUS/$SMALL_MEM"
  echo "Para manter o state coerente, ajuste ocpus/memory_gb no infra/terraform.tfvars."
fi
