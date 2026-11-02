# Contexto: servidor Minecraft na Oracle Cloud

Estado levantado em 2026-10-29, com o servidor PaperMC rodando. Use este arquivo para continuar em outra sessão; o próximo objetivo é **migrar para um modpack (All The Mods 11)**.

> Este arquivo não contém segredos: a senha do RCON e o `management-server-secret` ficam só na VM.

---

## 1. Infraestrutura (Terraform, em `~/oracle-cloud`)

| Item | Valor |
|---|---|
| Região (home) | `sa-saopaulo-1`. Tem **um único AD** (`PuVn:SA-SAOPAULO-1-AD-1`) |
| Conta | **Pay As You Go**, cobrada em **USD** |
| Compartment | `minecraft` |
| Autenticação | API Key em `~/.oci/config` (perfil `DEFAULT`) |
| Terraform | 1.12 ou mais novo, provider `oracle/oci ~> 7.0` |

**`bootstrap/`** (state local em `bootstrap/terraform.tfstate`):
- compartment, bucket `minecraft-tfstate` (versionado, namespace em `infra/backend.hcl`);
- quotas `free-tier-only` (`quotas.tf`);
- budget `limite-mensal` de **US$ 5** com alertas por e-mail em 10%, 50% e 100% do gasto real e em 100% da previsão;
- function de auto-stop (rede, OCIR, application, dynamic group e policy já criados). **A imagem nunca foi publicada**: `function_image` está vazio, então a function e a regra de evento não existem.

**`infra/`** (state remoto no bucket; init com `terraform init -backend-config=backend.hcl`):
- VCN `10.0.0.0/16` com subnet pública `10.0.1.0/24` e Internet Gateway;
- security list: 22/TCP só de `admin_cidr` (IP residencial `/32`, que pode mudar), 25565/TCP aberta, ICMP 3/4;
- VM `minecraft`: `VM.Standard.A1.Flex`, **4 OCPU / 24 GB / boot de 200 GB**, Ubuntu 24.04 aarch64.
- `terraform.tfvars`: `ocpus = 4`, `memory_gb = 24`, `boot_volume_gb = 200`, `ad_index = 0`.

**Acesso:**
- IP: `terraform -chdir=infra output -raw public_ip`
- SSH: `$(terraform -chdir=infra output -raw ssh_command)`
- Jogo: `terraform -chdir=infra output -raw minecraft_address`

### Limites do free tier: já estão todos no máximo
- **Compute:** a A1 usa os 4 OCPU / 24 GB inteiros. Não dá para criar uma segunda VM A1.
- **Disco:** o boot volume usa os 200 GB inteiros. Não dá para criar volume extra (a quota recusa).
- **Quotas ativas:** só A1 permitida (regional e por AD: `standard-a1-core-regional-count`, `standard-a1-core-count`, e os equivalentes de memória), block storage de 200 GB, load balancer e banco de dados zerados.
- **Porta nova** (ex.: 24454/UDP do Simple Voice Chat): precisa ser adicionada em `infra/network.tf` **e** no `iptables` da VM.

---

## 2. VM: estado atual

| Item | Valor |
|---|---|
| SO | Ubuntu 24.04.5 LTS, kernel 6.17 oracle, aarch64 |
| CPU / memória | 4 núcleos, 23 GB visíveis. Com o Paper usando 18 GB (pré-alocados), restam cerca de 3 GB disponíveis |
| Disco | 193 GB, cerca de 4 GB usados |
| Java | OpenJDK **25.0.4.1** (`openjdk-25-jre-headless`) |

### Serviço `minecraft` (systemd, habilitado no boot)
`/etc/systemd/system/minecraft.service`:
- `User=ubuntu`, `WorkingDirectory=/home/ubuntu/paper`
- `ExecStart=/usr/bin/java -Xms18G -Xmx18G <flags recomendadas do PaperMC (G1GC, AlwaysPreTouch...)> -jar paper.jar --nogui`
- `Restart=on-failure`, `RestartSec=10`, `SuccessExitStatus=0 1 143`

### PaperMC
- Versão **Paper 26.3, build 227** (`~/paper/paper.jar`)
- Plugins: só os embutidos (`spark`, `bStats`). Nenhum `.jar` instalado em `plugins/`.
- Mundo: `~/paper/world`, cerca de 30 MB (pouco explorado; não pré-gerado)
- TPS: 20.0 / 20.0 / 20.0

`server.properties` (valores relevantes):
```
motd=Server da gurizada
difficulty=hard
gamemode=survival
max-players=6
white-list=true
enforce-whitelist=true
online-mode=true
view-distance=16
simulation-distance=10
spawn-protection=0
enable-rcon=true
rcon.port=25575
```
- Operador e whitelist: `CalangoMolhado` (nível 4)

### RCON
- O `rcon-cli` 1.7.9 (itzg, linux_arm64) está em `/usr/local/bin/rcon-cli`.
- A conexão fica em `~/.rcon-cli.yaml` (permissão 600; host 127.0.0.1, porta 25575).
- A porta 25575 **não** está aberta externamente; só funciona de dentro da VM.
- Uso: `rcon-cli list`, `rcon-cli tps`, `rcon-cli op <nick>`, `rcon-cli` (console interativo).

### Firewall da VM (iptables, persistido com `netfilter-persistent`)
```
4 ACCEPT tcp dpt:22
5 ACCEPT tcp dpt:25565
6 REJECT all (icmp-host-prohibited)
```
Toda porta nova precisa ser inserida **antes** do `REJECT`. Hoje isso é `sudo iptables -I INPUT 6 ...`; confira com `sudo iptables -L INPUT -n --line-numbers`.

### Backups
Nenhum configurado: sem cron e sem backup de volume na OCI. O free tier permite 5 backups de volume.

---

## 3. Lições aprendidas (evitar repetir)
- **"Out of host capacity"** é comum na A1 em São Paulo. Foi resolvido com um script de tentativas (`scripts/retry-vm.sh`, rodado com `nohup setsid`, log em `retry.log`) e com o upgrade para PAYG.
- **Redimensionar a A1 (OCPU/memória) reinicia a VM, mesmo quando falha** por falta de capacidade.
- **Aumentar o disco** pelo Terraform é feito sem recriar nem reiniciar a VM. Depois, na VM: `echo 1 | sudo tee /sys/class/block/sda/device/rescan`, `sudo growpart /dev/sda 1` e `sudo resize2fs /dev/sda1`. O `oci-growfs` **não** existe no Ubuntu.
- A OCI **aceita nomes de quota inexistentes sem erro**, e mudanças de quota levam alguns minutos para propagar.
- Ao parar o script de tentativas com `pkill -f`, o padrão não pode aparecer no texto do próprio comando, senão ele mata o shell que o executa.
- O budget da OCI **só avisa**. A trava real são as quotas. O auto-stop está pendente (precisa de Docker local, que não está instalado no Arch).

---

## 4. Próximo objetivo: All The Mods 11

Levantado na sessão anterior:
- **ATM11:** NeoForge, Minecraft **26.1.2**, ainda em **beta** (versões 0.x). Exige **Java 25**, que já está instalado.
- **Memória recomendada:** 1–2 jogadores com 8 a 10 GB; 3–6 jogadores com 10 a 12 GB; 7 ou mais com 12 a 16 GB. Com `max-players=6`, usar **cerca de 12 a 14 GB** de heap.
- **Disco:** mínimo de cerca de 15 GB. Há sobra.
- **Gargalo:** o desempenho por núcleo da Ampere A1. Funciona para um grupo pequeno; bases grandes de Mekanism, AE2 ou Create e chunk loaders derrubam o TPS.
- **ARM:** quase todos os mods são Java puro. Testar o pack antes, porque mods com bibliotecas nativas podem falhar no aarch64.
- **Ajustes sugeridos para o ATM na A1:** `simulation-distance` entre 6 e 8, `view-distance` em torno de 10, limite de chunk loaders no FTB Chunks, pré-geração com Chunky (incluso no pack), reinício diário.

**Plano de migração esperado:**
1. Parar o Paper (`sudo systemctl stop minecraft`) e **preservar** `~/paper`, para poder voltar.
2. Baixar o *Server Pack* do ATM11 (CurseForge) em `~/atm11`, rodar o instalador do NeoForge e aceitar a EULA.
3. Copiar e ajustar o `server.properties` (whitelist, ops, RCON). O mundo do Paper (26.3) **não** serve para o ATM11 (26.1.2, com mods): começar um mundo novo.
4. Criar um serviço systemd próprio (ex.: `atm11.service`) ou trocar o `ExecStart` do `minecraft.service`. Usar o `run.sh` / `user_jvm_args.txt` do NeoForge com cerca de `-Xmx14G`.
5. Os jogadores instalam o mesmo pack no cliente (CurseForge ou Prism Launcher), na mesma versão do servidor.
6. Opcional: abrir portas extras de mods (ex.: Simple Voice Chat, 24454/UDP) no Terraform e no iptables.
