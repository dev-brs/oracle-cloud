resource "oci_identity_compartment" "minecraft" {
  compartment_id = var.tenancy_ocid
  name           = var.compartment_name
  description    = "Servidor de Minecraft (Always Free)"
  enable_delete  = true
}

data "oci_objectstorage_namespace" "this" {
  compartment_id = var.tenancy_ocid
}

resource "oci_objectstorage_bucket" "tfstate" {
  compartment_id = oci_identity_compartment.minecraft.id
  namespace      = data.oci_objectstorage_namespace.this.namespace
  name           = var.state_bucket_name
  access_type    = "NoPublicAccess"
  versioning     = "Enabled"
}
