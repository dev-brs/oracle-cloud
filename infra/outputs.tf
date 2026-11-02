output "public_ip" {
  value = oci_core_instance.vm.public_ip
}

output "ssh_command" {
  value = "ssh -i ${trimsuffix(var.ssh_public_key_path, ".pub")} ubuntu@${oci_core_instance.vm.public_ip}"
}
