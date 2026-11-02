output "compartment_id" {
  value = oci_identity_compartment.app.id
}

output "namespace" {
  value = data.oci_objectstorage_namespace.this.namespace
}

output "state_bucket_name" {
  value = oci_objectstorage_bucket.tfstate.name
}

output "function_image_repo" {
  description = "Destino do docker push da function de auto-stop."
  value       = "${var.region}.ocir.io/${data.oci_objectstorage_namespace.this.namespace}/${oci_artifacts_container_repository.budget_stop.display_name}"
}

output "infra_backend_hcl" {
  description = "Conteúdo para infra/backend.hcl."
  value       = <<-EOT
    bucket    = "${oci_objectstorage_bucket.tfstate.name}"
    namespace = "${data.oci_objectstorage_namespace.this.namespace}"
    region    = "${var.region}"
  EOT
}
