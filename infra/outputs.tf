output "public_ip" {
  value = oci_core_instance.minecraft.public_ip
}

output "ssh_command" {
  value = "ssh -i ${trimsuffix(var.ssh_public_key_path, ".pub")} ubuntu@${oci_core_instance.minecraft.public_ip}"
}

output "minecraft_address" {
  value = "${oci_core_instance.minecraft.public_ip}:${var.minecraft_port}"
}
