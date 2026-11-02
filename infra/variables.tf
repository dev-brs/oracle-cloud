variable "region" {
  description = "Home region da conta, ex.: sa-saopaulo-1."
  type        = string
}

variable "config_file_profile" {
  description = "Perfil do ~/.oci/config usado para autenticar."
  type        = string
  default     = "DEFAULT"
}

variable "compartment_id" {
  description = "OCID do compartment criado pelo bootstrap (output compartment_id)."
  type        = string
}

variable "ssh_public_key_path" {
  description = "Chave pública SSH autorizada na VM."
  type        = string
  default     = "~/.ssh/oci_vm.pub"
}

variable "admin_cidr" {
  description = "CIDR liberado para SSH, ex.: 1.2.3.4/32."
  type        = string
}

variable "ocpus" {
  description = "OCPUs da VM A1 (free tier: até 2 no total)."
  type        = number
  default     = 2
}

variable "memory_gb" {
  description = "Memória da VM A1 em GB (free tier: até 12 no total)."
  type        = number
  default     = 12
}

variable "boot_volume_gb" {
  description = "Tamanho do boot volume (free tier: até 200 GB somando todos os volumes)."
  type        = number
  default     = 100
}

variable "ad_index" {
  description = "Índice do availability domain; troque se der 'Out of host capacity'."
  type        = number
  default     = 0
}

variable "public_tcp_ports" {
  description = "Portas TCP abertas para a internet (o iptables da VM também precisa liberá-las)."
  type        = list(number)
  default     = [80, 443]
}

variable "vcn_dns_label" {
  description = "DNS label da VCN. Trocar recria a VCN, a subnet e a VM."
  type        = string
  default     = "vcn"
}
