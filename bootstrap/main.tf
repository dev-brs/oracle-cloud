resource "oci_identity_compartment" "app" {
  compartment_id = var.tenancy_ocid
  name           = var.compartment_name
  description    = "VM Always Free e recursos de apoio"
  enable_delete  = true
}

moved {
  from = oci_identity_compartment.minecraft
  to   = oci_identity_compartment.app
}

data "oci_objectstorage_namespace" "this" {
  compartment_id = var.tenancy_ocid
}

resource "oci_objectstorage_bucket" "tfstate" {
  compartment_id = oci_identity_compartment.app.id
  namespace      = data.oci_objectstorage_namespace.this.namespace
  name           = var.state_bucket_name
  access_type    = "NoPublicAccess"
  versioning     = "Enabled"
}
