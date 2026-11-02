# VM Ampere A1 na Oracle Cloud: Always Free + trava de gastos

Terraform que sobe uma VM **Ampere A1** do Always Free da Oracle Cloud (2 OCPU / 12 GB / 200 GB), com quotas, budget e uma guarda de custo para a conta não gerar cobrança. A VM vem vazia (Ubuntu 24.04 aarch64); o serviço que ela vai hospedar é instalado à parte.

```
bootstrap/   state LOCAL: compartment, bucket do state, quotas, budget, IAM da guarda de custo, function de auto-stop
infra/       state no bucket: VCN, subnet pública, VM Ampere A1
scripts/     oci-cost.py (custo e guarda), cost-guard/ (timer da guarda na VM), retry-vm.sh (contorna "Out of host capacity")
CONTEXT.md   estado atual e lições aprendidas
```

> ⚠️ **É necessário ter a conta em Pay As You Go (PAYG).** Contas só Free Tier quase nunca conseguem alocar a A1 ("Out of host capacity" por horas ou dias). Com PAYG, os recursos Always Free **continuam gratuitos**, mas **tudo o que passar da franquia é cobrado sem erro nem aviso**. As quotas e a guarda de custo deste repositório existem para isso.

## Franquia Always Free da A1

A franquia é medida em **horas por mês**, somando todas as VMs A1 da tenancy: **1.500 OCPU-hora e 9.000 GB-hora** (equivale a 2 OCPU / 12 GB ligados o mês todo). A Oracle já mudou esse número antes (era 3.000 / 18.000); confira a [página oficial](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm) e ajuste `A1_FREE` em `scripts/oci-cost.py` e as quotas se mudar de novo.

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
2. **Upgrade para Pay As You Go** (Billing & Cost Management → Upgrade and Manage Payment → *Upgrade to Pay As You Go*). **Obrigatório na prática**: sem isso, a criação da A1 falha por falta de capacidade quase sempre. A aprovação pode levar alguns minutos ou horas e exige um cartão (a OCI faz uma pré-autorização temporária).
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
6. **Chave SSH**: `ssh-keygen -t ed25519 -f ~/.ssh/oci_vm`.
7. **Ferramentas**: Terraform >= 1.12, Python 3 com o SDK `oci` (seção 4) e, para a function de auto-stop, Docker (ou Podman). A OCI CLI é opcional.

## 2. Bootstrap (uma vez)

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars   # preencha tenancy_ocid, region, alert_email
terraform init
terraform apply
```

Confirme a inscrição no e-mail que a OCI enviar. Opcional: publique a function de auto-stop do budget (segunda camada; a guarda principal é a da seção 4):

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
  - compute limitado à A1 (2 OCPU / 12 GB); qualquer outro shape, GPU incluída, é recusado;
  - block storage limitado a 200 GB;
  - load balancer e bancos de dados zerados.
- **Guarda de custo** (`cost_guard.tf` + seção 4): a VM confere o custo a cada hora e se desliga quando a cobrança começa.
- **Budget** (`budget.tf`): US$ 5/mês, com e-mail a 10%, 50% e 100% do gasto real e a 100% da previsão.
- **Auto-stop do budget** (opcional): todo alerta gera o evento `com.oraclecloud.budgets.createtriggeredalert`, que chama a function. Se o gasto real >= o budget, ela faz SOFTSTOP em todas as VMs do compartment.

> A OCI calcula custo e uso com algumas horas de atraso. As quotas impedem criar recursos pagos; a guarda de custo cobre o que as quotas não pegam (ex.: horas da A1 acima da franquia).

## 3. Infra

```bash
cd ../infra
terraform -chdir=../bootstrap output -raw infra_backend_hcl > backend.hcl
cp terraform.tfvars.example terraform.tfvars   # compartment_id (output do bootstrap), region, admin_cidr
terraform init -backend-config=backend.hcl
terraform apply
```

Se der "Out of host capacity" (comum em São Paulo), use o `scripts/retry-vm.sh`, que repete o `terraform apply` até a VM ser criada:

```bash
# a partir da raiz do repositório; roda desacoplado do terminal
nohup setsid scripts/retry-vm.sh > retry.log 2>&1 &
tail -f retry.log           # "OK" indica sucesso
```

- Tentativas e intervalo: `TRIES` (2880) e `SLEEP` (60 s), ~48 h.
- Para parar: `pkill -f 'retry-vm[.]sh'` (os colchetes evitam que o `pkill` mate o próprio shell).
- Se a região tiver mais de um AD, trocar `ad_index` (0, 1, 2) no tfvars também ajuda.

Para aumentar o disco depois (`boot_volume_gb`, até 200): `terraform apply` não recria nem reinicia a VM; na VM rode `echo 1 | sudo tee /sys/class/block/sda/device/rescan`, `sudo growpart /dev/sda 1` e `sudo resize2fs /dev/sda1`.

## 4. Custo e guarda de cobrança

`scripts/oci-cost.py` usa o SDK Python da OCI:

```bash
python3 -m venv ~/.venvs/oci && ~/.venvs/oci/bin/pip install oci

~/.venvs/oci/bin/python scripts/oci-cost.py              # report: custo por SKU (mês atual e anterior) e uso da A1 x franquia
~/.venvs/oci/bin/python scripts/oci-cost.py guard --dry-run
```

O `guard` dá SOFTSTOP nas VMs ligadas se o custo do mês passar de `--max-cost` (padrão 0) **ou** se o uso da A1 chegar à franquia menos uma margem (`--margin-hours`, padrão 24 h do shape ligado, para cobrir o atraso dos dados). Para testar o caminho de desligar sem desligar: `guard --dry-run --max-cost -1`.

**Na VM**, o guard roda a cada hora por um timer do systemd, autenticado como *instance principal* (dynamic group e policy em `bootstrap/cost_guard.tf`). Instale ou atualize com:

```bash
scripts/cost-guard/install.sh      # VM_HOST=ubuntu@<ip> e VM_KEY=<chave> sobrescrevem o padrão
```

Logs: `journalctl -u cost-guard` na VM. Depois de um desligamento, a VM só volta quando você a ligar, de preferência no mês seguinte: `scripts/oci-cost.py start` (ou Console → Compute → Start). O `terraform apply` **não** liga uma VM parada.

### Testar a guarda

1. Sem desligar nada, no PC e na VM:
   ```bash
   ~/.venvs/oci/bin/python scripts/oci-cost.py guard --dry-run --max-cost -1     # deve listar a VM como alvo
   ssh ... 'sudo /opt/cost-guard/venv/bin/python /opt/cost-guard/oci-cost.py guard --auth instance_principal --dry-run --max-cost -1'
   ```
2. Ponta a ponta, desligando de verdade pela própria VM (a VM fica fora do ar por alguns minutos):
   ```bash
   ssh ... 'sudo /opt/cost-guard/venv/bin/python /opt/cost-guard/oci-cost.py guard --auth instance_principal --max-cost -1'
   ~/.venvs/oci/bin/python scripts/oci-cost.py          # a VM deve aparecer STOPPING e depois STOPPED
   ~/.venvs/oci/bin/python scripts/oci-cost.py start    # religa; o timer volta a rodar 5 min após o boot
   ```

## 5. Expor um serviço

1. Adicione a porta em `public_tcp_ports` no `infra/terraform.tfvars` (padrão `[80, 443]`) e rode `terraform apply`.
2. Libere a porta **também no iptables da VM**: as imagens Ubuntu da OCI bloqueiam tudo com uma regra `REJECT`. Insira **antes** dela (confira a posição com `sudo iptables -L INPUT -n --line-numbers`):
   ```bash
   sudo iptables -I INPUT <posição do REJECT> -p tcp --dport 80 -j ACCEPT
   sudo netfilter-persistent save
   ```

## 6. Testes da trava

- Console → Compute → criar VM `VM.Standard.E4.Flex`, ou uma A1 com mais de 2 OCPU: deve falhar com erro de quota.
- `scripts/oci-cost.py guard --dry-run --max-cost -1` (no PC) mostra quais VMs seriam desligadas.
- Auto-stop do budget (se publicado): `oci fn function invoke --function-id <id> --file - --body '{}'`. Com gasto abaixo do limite, a resposta é `{"stopped": []}`.
