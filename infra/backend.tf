# bucket, namespace e region vêm de backend.hcl (gerado pelo output infra_backend_hcl do bootstrap):
#   terraform init -backend-config=backend.hcl
terraform {
  backend "oci" {
    key                 = "infra/terraform.tfstate"
    auth                = "APIKey"
    config_file_profile = "DEFAULT"
  }
}
