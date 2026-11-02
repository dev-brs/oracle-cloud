# Guarda de custo: a própria VM roda scripts/oci-cost.py guard a cada hora (instance principal)
# e se desliga quando a cobrança começa. Veja scripts/cost-guard/.

resource "oci_identity_dynamic_group" "vm_instances" {
  compartment_id = var.tenancy_ocid
  name           = "vm-instances"
  description    = "Instancias do compartment ${var.compartment_name}"
  matching_rule  = "ALL {instance.compartment.id = '${oci_identity_compartment.app.id}'}"
}

resource "oci_identity_policy" "cost_guard" {
  compartment_id = var.tenancy_ocid
  name           = "vm-cost-guard"
  description    = "Permite as VMs lerem o custo da tenancy e se desligarem"

  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.vm_instances.name} to read usage-report in tenancy",
    "Allow dynamic-group ${oci_identity_dynamic_group.vm_instances.name} to read instances in compartment ${oci_identity_compartment.app.name}",
    # Só ligar/desligar; nada de alterar ou apagar instâncias.
    "Allow dynamic-group ${oci_identity_dynamic_group.vm_instances.name} to use instances in compartment ${oci_identity_compartment.app.name} where request.permission = 'INSTANCE_POWER_ACTIONS'",
  ]
}
