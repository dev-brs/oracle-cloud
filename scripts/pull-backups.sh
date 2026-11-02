#!/usr/bin/env bash
# Copia para este PC os backups da VM (~/backups/<servidor>/*.tar.zst) que ainda não estão aqui.
# Uso: scripts/pull-backups.sh [destino]   (padrão: %USERPROFILE%\minecraft-backups, no disco do Windows)
# MC_PULL_KEEP=N mantém só os N mais recentes por servidor aqui (padrão: 3; 0 = guarda todos).
# MC_HOST=ubuntu@<ip> e MC_KEY=<chave> sobrescrevem o host (padrão: output public_ip do infra/) e a chave SSH.
set -euo pipefail
if [[ -z ${MC_HOST:-} ]]; then
  IP=$(terraform -chdir="$(dirname "$0")/../infra" output -raw public_ip) \
    || { echo "Não consegui ler o IP do Terraform; defina MC_HOST=ubuntu@<ip>."; exit 1; }
  MC_HOST=ubuntu@$IP
fi
HOST=$MC_HOST
KEY=${MC_KEY:-~/.ssh/oci_minecraft}
# Pasta do usuário no Windows (ex.: C:\Users\Fulano -> /mnt/c/Users/Fulano), lida pelo interop do WSL
win_home() {
  local p
  p=$(cd /mnt/c && cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r') || return 1
  [[ -n $p && $p != *%* ]] && wslpath -u "$p"
}
if [[ -n ${1:-} ]]; then
  DEST=$1
else
  WIN_HOME=$(win_home) || { echo "Não consegui achar a pasta do Windows; informe o destino."; exit 1; }
  DEST=$WIN_HOME/minecraft-backups
fi
KEEP=${MC_PULL_KEEP:-3}
SSH=(ssh -i "$KEY" -o ConnectTimeout=10 "$HOST")

# Os nomes têm data e hora, então a ordem alfabética é a cronológica.
# Com KEEP, só os N mais recentes de cada servidor (senão os apagados aqui voltariam).
mapfile -t remote < <("${SSH[@]}" 'cd ~/backups && ls -1 */*.tar.zst 2>/dev/null' \
  | sort | awk -F/ -v k="$KEEP" '{n[$1]++; f[$1, n[$1]] = $0}
      END {for (s in n) for (i = 1; i <= n[s]; i++) if (k == 0 || i > n[s] - k) print f[s, i]}')
[[ ${#remote[@]} -gt 0 ]] || { echo "Nenhum backup na VM."; exit 0; }

new=0
for f in "${remote[@]}"; do
  [[ -f $DEST/$f ]] && continue
  mkdir -p "$DEST/$(dirname "$f")"
  echo "== $f"
  scp -q -i "$KEY" "$HOST:backups/$f" "$DEST/$f.part"
  zstd -tq "$DEST/$f.part" || { echo "Arquivo corrompido, descartado: $f"; rm -f "$DEST/$f.part"; continue; }
  mv "$DEST/$f.part" "$DEST/$f"
  new=$((new + 1))
done

if (( KEEP > 0 )); then
  for dir in "$DEST"/*/; do
    ls -1t "$dir"*.tar.zst 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r -d '\n' rm --
  done
fi

echo "$new backup(s) novo(s) em $DEST"
du -sh "$DEST"/*/ 2>/dev/null || true
