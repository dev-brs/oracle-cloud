variable "tenancy_ocid" {
  description = "OCID da tenancy (Console > Profile > Tenancy)."
  type        = string
}

variable "region" {
  description = "Home region da conta, ex.: sa-saopaulo-1."
  type        = string
}

variable "config_file_profile" {
  description = "Perfil do ~/.oci/config usado para autenticar."
  type        = string
  default     = "DEFAULT"
}

variable "compartment_name" {
  description = "Nome do compartment que agrupa a VM e os recursos de apoio."
  type        = string
  default     = "app"
}

variable "state_bucket_name" {
  description = "Nome do bucket que guarda o state do diretório infra/."
  type        = string
  default     = "vm-tfstate"
}

variable "budget_amount" {
  description = "Valor mensal do budget, na moeda da conta (ex.: USD -> 5 = US$ 5)."
  type        = number
  default     = 5
}

variable "alert_email" {
  description = "E-mail que recebe os alertas do budget."
  type        = string
}

variable "function_image" {
  description = "Imagem da function de auto-stop no OCIR (<region>.ocir.io/<namespace>/guardrails/budget-stop:1). Deixe null no primeiro apply; preencha depois do docker push."
  type        = string
  default     = null
}
