# Budget mensal na tenancy inteira. Por si só ele só avisa; quem desliga as VMs
# é a function abaixo, acionada pelo evento de alerta do budget.
resource "oci_budget_budget" "monthly" {
  compartment_id = var.tenancy_ocid
  display_name   = "limite-mensal"
  description    = "Trava de gastos da conta"
  amount         = var.budget_amount
  reset_period   = "MONTHLY"
  target_type    = "COMPARTMENT"
  targets        = [var.tenancy_ocid]
}

locals {
  alert_rules = {
    actual-10    = { type = "ACTUAL", threshold = 10 }
    actual-50    = { type = "ACTUAL", threshold = 50 }
    forecast-100 = { type = "FORECAST", threshold = 100 }
    actual-100   = { type = "ACTUAL", threshold = 100 }
  }
}

resource "oci_budget_alert_rule" "this" {
  for_each = local.alert_rules

  budget_id      = oci_budget_budget.monthly.id
  display_name   = each.key
  type           = each.value.type
  threshold      = each.value.threshold
  threshold_type = "PERCENTAGE"
  recipients     = var.alert_email
  message        = "Budget da OCI atingiu ${each.value.threshold}% (${lower(each.value.type)}). Ao atingir 100% real, as VMs do compartment ${var.compartment_name} sao paradas automaticamente."
}

# ---------------------------------------------------------------------------
# Auto-stop: evento do budget -> OCI Function -> STOP nas instâncias.
# ---------------------------------------------------------------------------

# Rede mínima e privada para a function falar com as APIs da OCI pelo Service Gateway.
data "oci_core_services" "all" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

resource "oci_core_vcn" "functions" {
  compartment_id = oci_identity_compartment.minecraft.id
  display_name   = "functions-vcn"
  cidr_blocks    = ["10.10.0.0/16"]
  dns_label      = "fnvcn"
}

resource "oci_core_service_gateway" "functions" {
  compartment_id = oci_identity_compartment.minecraft.id
  vcn_id         = oci_core_vcn.functions.id
  display_name   = "functions-sgw"

  services {
    service_id = data.oci_core_services.all.services[0].id
  }
}

resource "oci_core_route_table" "functions" {
  compartment_id = oci_identity_compartment.minecraft.id
  vcn_id         = oci_core_vcn.functions.id
  display_name   = "functions-rt"

  route_rules {
    destination       = data.oci_core_services.all.services[0].cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.functions.id
  }
}

resource "oci_core_security_list" "functions" {
  compartment_id = oci_identity_compartment.minecraft.id
  vcn_id         = oci_core_vcn.functions.id
  display_name   = "functions-sl"

  egress_security_rules {
    destination      = data.oci_core_services.all.services[0].cidr_block
    destination_type = "SERVICE_CIDR_BLOCK"
    protocol         = "6"
  }
}

resource "oci_core_subnet" "functions" {
  compartment_id             = oci_identity_compartment.minecraft.id
  vcn_id                     = oci_core_vcn.functions.id
  display_name               = "functions-private"
  cidr_block                 = "10.10.1.0/24"
  dns_label                  = "fn"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.functions.id
  security_list_ids          = [oci_core_security_list.functions.id]
}

resource "oci_artifacts_container_repository" "budget_stop" {
  compartment_id = oci_identity_compartment.minecraft.id
  display_name   = "minecraft/budget-stop"
  is_public      = false
}

resource "oci_functions_application" "guardrails" {
  compartment_id = oci_identity_compartment.minecraft.id
  display_name   = "guardrails"
  subnet_ids     = [oci_core_subnet.functions.id]
  shape          = "GENERIC_X86"
}

resource "oci_functions_function" "budget_stop" {
  count = var.function_image == null ? 0 : 1

  application_id     = oci_functions_application.guardrails.id
  display_name       = "budget-stop"
  image              = var.function_image
  memory_in_mbs      = 128
  timeout_in_seconds = 120

  config = {
    BUDGET_ID      = oci_budget_budget.monthly.id
    COMPARTMENT_ID = oci_identity_compartment.minecraft.id
  }
}

# Os eventos de budget são emitidos no compartment raiz. Todo alerta dispara a
# function; ela própria confere se o gasto real já chegou a 100% antes de parar algo.
resource "oci_events_rule" "budget_stop" {
  count = var.function_image == null ? 0 : 1

  compartment_id = var.tenancy_ocid
  display_name   = "budget-alert-stop-instances"
  is_enabled     = true
  condition = jsonencode({
    eventType = ["com.oraclecloud.budgets.createtriggeredalert"]
  })

  actions {
    actions {
      action_type = "FAAS"
      is_enabled  = true
      function_id = oci_functions_function.budget_stop[0].id
    }
  }
}

# ---------------------------------------------------------------------------
# IAM
# ---------------------------------------------------------------------------

resource "oci_identity_dynamic_group" "budget_stop" {
  compartment_id = var.tenancy_ocid
  name           = "minecraft-budget-stop-fn"
  description    = "Functions do compartment ${var.compartment_name}"
  matching_rule  = "ALL {resource.type = 'fnfunc', resource.compartment.id = '${oci_identity_compartment.minecraft.id}'}"
}

resource "oci_identity_policy" "budget_stop" {
  compartment_id = var.tenancy_ocid
  name           = "minecraft-budget-stop"
  description    = "Permite a function de auto-stop ler o budget e parar VMs"

  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.budget_stop.name} to read usage-budgets in tenancy",
    "Allow dynamic-group ${oci_identity_dynamic_group.budget_stop.name} to manage instance-family in compartment ${oci_identity_compartment.minecraft.name}",
    "Allow service faas to use virtual-network-family in compartment ${oci_identity_compartment.minecraft.name}",
    "Allow service faas to read repos in tenancy",
  ]
}
