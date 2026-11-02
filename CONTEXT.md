# Contexto: VM Always Free na Oracle Cloud

Estado em 2026-11-02. Use este arquivo para continuar em outra sessão. O próximo objetivo é **hospedar um web app** (ainda não definido) na VM.

> Este arquivo não contém segredos.

---

## 1. Infraestrutura (Terraform, em `~/oracle-cloud`)

| Item | Valor |
|---|---|
| Região (home) | `sa-saopaulo-1`. Tem **um único AD** (`PuVn:SA-SAOPAULO-1-AD-1`) |
| Conta | **Pay As You Go**, cobrada em **BRL** |
| Compartment | `app` (renomeado de `minecraft`; o OCID não mudou) |
| Autenticação | API Key em `~/.oci/config` (perfil `DEFAULT`) |
| Terraform | 1.12 ou mais novo, provider `oracle/oci ~> 7.0` |

**`bootstrap/`** (state local em `bootstrap/terraform.tfstate`):
- compartment, bucket do state (`minecraft-tfstate`, nome antigo fixado no tfvars local; versionado);
- quotas `free-tier-only` (`quotas.tf`): A1 2 OCPU / 12 GB, block storage 200 GB, LB e DB zerados;
- dynamic group `vm-instances` + policy `vm-cost-guard` (`cost_guard.tf`) para a guarda de custo na VM;
- budget `limite-mensal` de 5 com alertas por e-mail. A function de auto-stop do budget **nunca foi publicada** (`function_image` vazio; precisa de Docker).

**`infra/`** (state remoto no bucket; init com `terraform init -backend-config=backend.hcl`):
- VCN `10.0.0.0/16` (`dns_label = "minecraft"` fixado no tfvars local: trocar recria VCN, subnet e VM), subnet pública `10.0.1.0/24` e Internet Gateway;
- security list: 22/TCP só de `admin_cidr` (IP residencial `/32`, que pode mudar), `public_tcp_ports` = 80 e 443, ICMP 3/4;
- VM `vm`: `VM.Standard.A1.Flex`, **2 OCPU / 12 GB / boot de 200 GB**, Ubuntu 24.04 aarch64.
  **Pendente em 2026-11-02:** a redução de 4/24 para 2/12 falhou com "Out of host capacity"; a VM ainda está em 4/24 com o nome antigo `minecraft`. Rodar `scripts/retry-vm.sh` até o `terraform apply` do infra passar. Até lá, a guarda de custo desliga a VM antes de a franquia acabar (~15/11).

**Acesso:**
- IP: `terraform -chdir=infra output -raw public_ip` (IP efêmero; muda só se a VM for recriada)
- SSH: `$(terraform -chdir=infra output -raw ssh_command)` (a chave local ainda é `~/.ssh/oci_minecraft`, fixada no tfvars)

## 2. VM: estado atual
- Limpa por dentro em 2026-11-02 (não foi reinstalada, veja as lições): servidores, units, scripts, Java e a regra 25565 do iptables removidos. **Nenhum serviço de aplicação.** Ficaram as ferramentas neovim, btop, tree, unzip e glow (snap), além do agente da Oracle.
- Instalado: só a guarda de custo (`/opt/cost-guard`, `cost-guard.timer` a cada hora; veja README seção 4).
- iptables: só a 22 liberada antes do `REJECT`. Para expor 80/443, ver README seção 5.
- Histórico: antes a VM rodava servidores Minecraft (ATM10, ATM11, Paper). Backup completo (home, units, scripts, iptables) em `C:\Users\Bernardo Rodrigues\minecraft-backups\vm-reset-20261102\vm-full.tar.zst`.

## 3. Custo
- `scripts/oci-cost.py` (report) mostra o custo por SKU e o uso da A1 contra a franquia; `guard` desliga as VMs se houver cobrança.
- Novembro/2026 começou com a VM em 4/24 (163 OCPU-hora nos primeiros ~41 h). Mesmo em 2/12, o mês fecha um pouco acima de 1.500 OCPU-hora; a guarda deve desligar a VM perto de 29–30/11. Religar em 01/12.

## 4. Lições aprendidas (evitar repetir)
- **A franquia A1 caiu de 3.000 / 18.000 para 1.500 OCPU-hora / 9.000 GB-hora por mês** (2 OCPU / 12 GB). Com PAYG, o excedente é **cobrado sem erro nem aviso**; as quotas estavam em 4/24 e não barraram. Conferir a página do Always Free de tempos em tempos.
- **"Out of host capacity"** é comum na A1 em São Paulo. Resolvido com `scripts/retry-vm.sh` (`nohup setsid`, log em `retry.log`) e com o upgrade para PAYG. Reduzir o shape também pode falhar por capacidade, porque o resize muda a VM de host.
- **Reinstalar o disco de boot** (UpdateInstance com `source_details` de imagem) mantém a VM e o IP, mas cria o disco novo antes de apagar o antigo: com o boot em 200 GB e a quota em 200 GB, a OCI recusa (`bootVolumeQuota`). Seria preciso subir a quota temporariamente ou usar um boot menor.
- **Redimensionar a A1 (OCPU/memória) reinicia a VM, mesmo quando falha** por falta de capacidade.
- **Renomear sem recriar:** `display_name`, `hostname_label` e o nome do compartment mudam in-place; `dns_label` da VCN, nomes de dynamic group/policy e `display_name` do repositório OCIR forçam replace. Use blocos `moved {}` ao renomear endereços do Terraform.
- **Aumentar o disco** pelo Terraform é feito sem recriar nem reiniciar a VM. Depois, na VM: `echo 1 | sudo tee /sys/class/block/sda/device/rescan`, `sudo growpart /dev/sda 1` e `sudo resize2fs /dev/sda1`. O `oci-growfs` **não** existe no Ubuntu.
- A OCI **aceita nomes de quota inexistentes sem erro**, e mudanças de quota levam alguns minutos para propagar.
- Ao parar o script de tentativas com `pkill -f`, o padrão não pode aparecer no texto do próprio comando, senão ele mata o shell que o executa.
- O budget da OCI **só avisa**. Quem impede gasto são as quotas e a guarda de custo.
- Portas novas precisam ser liberadas na security list (`public_tcp_ports`) **e** no iptables da VM, antes da regra `REJECT`.
