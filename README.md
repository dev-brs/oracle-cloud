# Minecraft (PaperMC) na Oracle Cloud: Always Free + trava de gastos

Terraform que sobe um servidor Minecraft em uma VM **Ampere A1** do Always Free da Oracle Cloud (até 4 OCPU / 24 GB / 200 GB), com quotas, budget e auto-stop para a conta não gerar cobrança.

```
bootstrap/   state LOCAL: compartment, bucket do state, quotas, budget de US$ 5, function de auto-stop
infra/       state no bucket: VCN, subnet pública, VM Ampere A1
scripts/     retry-vm.sh (cria a VM contornando "Out of host capacity"), pull-backups.sh
CONTEXT.md   anotações do servidor em produção e lições aprendidas
```

> ⚠️ **É necessário ter a conta em Pay As You Go (PAYG).** Contas só Free Tier quase nunca conseguem alocar a A1 ("Out of host capacity" por horas ou dias). Com PAYG, os recursos Always Free **continuam gratuitos**, a OCI dá prioridade maior na alocação, e as quotas e o budget deste repositório impedem que algo pago seja criado. Veja o passo 2 dos pré-requisitos.

## Segredos: o que não vai para o Git

O `.gitignore` já exclui tudo isto. Cada pessoa cria os seus a partir dos `*.example`:

| Arquivo | Conteúdo | Como criar |
|---|---|---|
| `bootstrap/terraform.tfvars` | OCID da tenancy, e-mail de alerta | `cp terraform.tfvars.example terraform.tfvars` |
| `infra/terraform.tfvars` | OCID do compartment, seu IP (`admin_cidr`) | `cp terraform.tfvars.example terraform.tfvars` |
| `infra/backend.hcl` | namespace do Object Storage | gerado pelo output do bootstrap (passo 3) |
| `*.tfstate` | state do Terraform (tem OCIDs e IPs) | criado pelo `terraform apply` |
| `retry.log*` | log do `retry-vm.sh` (tem o IP público) | criado pelo script |
| `~/.oci/`, `~/.ssh/` | API key e chave SSH | ficam fora do repositório |

Nunca escreva Auth Tokens, senhas ou chaves em arquivos versionados (README incluído).

## 1. Pré-requisitos (manual)

1. **Conta OCI.** A *Home Region* não muda depois, e a A1 grátis só existe nela.
2. **Upgrade para Pay As You Go** (Billing & Cost Management → Upgrade and Manage Payment → *Upgrade to Pay As You Go*). **Obrigatório na prática**: sem isso, a criação da A1 falha por falta de capacidade quase sempre. O Always Free continua grátis; as travas da seção 2 impedem gastos. A aprovação pode levar alguns minutos ou horas e exige um cartão (a OCI faz uma pré-autorização temporária).
3. **Moeda da conta** (Billing → Subscription). `budget_amount` está na moeda da conta: 5 = R$ 5 se for BRL.
4. **API Signing Key**: Profile → My profile → API keys → *Add API key* → *Generate key pair*.
   - Salve a chave privada em `~/.oci/oci_api_key.pem` e rode `chmod 600`.
   - Crie `~/.oci/config` (`chmod 600`). Se você fechou a janela de preview, o trecho também aparece em *API keys* → menu ⋮ da chave → *View configuration file*. Ou monte à mão:
     ```ini
     [DEFAULT]
     user=ocid1.user.oc1..       # Profile → My profile → OCID
     fingerprint=xx:xx:...       # openssl rsa -pubout -outform DER -in ~/.oci/oci_api_key.pem | openssl md5 -c
     tenancy=ocid1.tenancy.oc1.. # Profile → Tenancy → OCID
     region=sa-saopaulo-1        # sua home region
     key_file=~/.oci/oci_api_key.pem
     ```
5. **Auth Token** (Profile → My profile → Auth tokens): é a senha do `docker login` no OCIR. Ele só aparece uma vez; guarde num gerenciador de senhas, **não** no repositório.
6. **Chave SSH**: `ssh-keygen -t ed25519 -f ~/.ssh/oci_minecraft`.
7. **Ferramentas**: Terraform >= 1.12 e Docker (ou Podman). A OCI CLI é opcional.

## 2. Bootstrap (uma vez)

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars   # preencha tenancy_ocid, region, alert_email
terraform init
terraform apply
```

Confirme a inscrição no e-mail que a OCI enviar. Depois, publique a function de auto-stop:

```bash
REPO=$(terraform output -raw function_image_repo)
docker login <region>.ocir.io        # usuário: <namespace>/<seu-email>  senha: Auth Token
docker build --platform linux/amd64 -t $REPO:1 functions/budget_stop
docker push $REPO:1
echo "function_image = \"$REPO:1\"" >> terraform.tfvars
terraform apply                      # cria a function e a regra de evento
```

Guarde o `bootstrap/terraform.tfstate` fora do Git (ex.: backup pessoal): ele é o único state local.

### O que as travas fazem
- **Quotas** (`quotas.tf`), na tenancy inteira:
  - compute limitado à A1 (4 OCPU / 24 GB); qualquer outro shape, GPU incluída, é recusado;
  - block storage limitado a 200 GB;
  - load balancer e bancos de dados zerados.
- **Budget** (`budget.tf`): US$ 5/mês, com e-mail a 10%, 50% e 100% do gasto real e a 100% da previsão.
- **Auto-stop**: todo alerta gera o evento `com.oraclecloud.budgets.createtriggeredalert`, que chama a function. Se o gasto real >= o budget, ela faz SOFTSTOP em todas as VMs do compartment `minecraft`.

> A OCI calcula o gasto do budget com algumas horas de atraso. A trava que realmente impede gasto são as quotas; o budget e o auto-stop são a segunda camada.

## 3. Infra

```bash
cd ../infra
terraform -chdir=../bootstrap output -raw infra_backend_hcl > backend.hcl
cp terraform.tfvars.example terraform.tfvars   # compartment_id (output do bootstrap), region, admin_cidr
terraform init -backend-config=backend.hcl
```

Agora crie a VM. Há dois caminhos:

### 3a. Direto (se houver capacidade)

```bash
terraform apply     # usa ocpus/memory_gb do tfvars (padrão 4 / 24)
```

### 3b. Com o `scripts/retry-vm.sh` (recomendado)

A A1 vive sem capacidade ("Out of host capacity"), principalmente em São Paulo. Uma VM menor encontra espaço mais fácil, e depois dá para redimensionar. O script faz isso em duas fases, repetindo o `terraform apply` até dar certo:

| Fase | Shape | Tentativas padrão |
|---|---|---|
| 1. Criar | **2 OCPU / 12 GB** | 2880, a cada 60 s (~48 h) |
| 2. Redimensionar | **4 OCPU / 24 GB** | 480, a cada 30 s (~4 h) |

```bash
# a partir da raiz do repositório; roda desacoplado do terminal
nohup setsid scripts/retry-vm.sh > retry.log 2>&1 &
tail -f retry.log           # "FASE1 OK" e "FASE2 OK" indicam sucesso
```

- Se a fase 2 der certo, o script grava `ocpus = 4` e `memory_gb = 24` no `infra/terraform.tfvars`.
- Se a fase 2 esgotar as tentativas, a VM fica com 2/12. Ajuste o tfvars para `ocpus = 2` / `memory_gb = 12` (senão o próximo `terraform apply` tenta redimensionar de novo) e rode só a fase 2 depois: `SKIP_PHASE1=1 nohup setsid scripts/retry-vm.sh > retry.log 2>&1 &`.
- **Cada tentativa de redimensionar reinicia a VM, mesmo quando falha.** Rode a fase 2 antes de instalar o servidor, ou com o servidor parado.
- Os valores são ajustáveis por variável de ambiente (`SMALL_OCPUS`, `SMALL_MEM`, `BIG_OCPUS`, `BIG_MEM`, `*_TRIES`, `*_SLEEP`); veja o cabeçalho do script.
- Para parar: `pkill -f 'retry-vm[.]sh'` (os colchetes evitam que o `pkill` mate o próprio shell).
- Se a região tiver mais de um AD, trocar `ad_index` (0, 1, 2) no tfvars também ajuda.

## 4. Instalar o PaperMC (na VM)

```bash
$(terraform output -raw ssh_command)

sudo apt update && sudo apt install -y openjdk-25-jre-headless
# As imagens Ubuntu da OCI bloqueiam portas no iptables (insira ANTES da regra REJECT; confira com
# sudo iptables -L INPUT -n --line-numbers):
sudo iptables -I INPUT 5 -p tcp --dport 25565 -j ACCEPT
sudo netfilter-persistent save

mkdir ~/paper && cd ~/paper
# baixe o jar mais recente em https://papermc.io/downloads/paper
echo "eula=true" > eula.txt
java -Xms4G -Xmx18G -jar paper-*.jar --nogui
```

Conecte o jogo em `terraform output -raw minecraft_address`.

Para aumentar o disco depois (`boot_volume_gb`, até 200): `terraform apply` não recria nem reinicia a VM; na VM rode `echo 1 | sudo tee /sys/class/block/sda/device/rescan`, `sudo growpart /dev/sda 1` e `sudo resize2fs /dev/sda1`.

## 5. Backups para o PC

`scripts/pull-backups.sh [destino]` copia por `scp` os `~/backups/<servidor>/*.tar.zst` da VM que ainda não existem localmente e valida cada arquivo com `zstd -t`.

- O host vem de `terraform -chdir=infra output -raw public_ip`; sobrescreva com `MC_HOST=ubuntu@<ip>` e a chave com `MC_KEY=<caminho>`.
- Destino padrão: `%USERPROFILE%\minecraft-backups` (feito para WSL).
- `MC_PULL_KEEP=N` mantém só os N mais recentes por servidor (padrão 3; 0 = todos).

## 6. Testes da trava

- Console → Compute → criar VM `VM.Standard.E4.Flex`: deve falhar com erro de quota.
- Testar o auto-stop sem gastar: `oci fn function invoke --function-id <id> --file - --body '{}'`. Com gasto abaixo do limite, a resposta é `{"stopped": []}`.
