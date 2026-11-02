resource "oci_core_vcn" "minecraft" {
  compartment_id = var.compartment_id
  display_name   = "minecraft-vcn"
  cidr_blocks    = ["10.0.0.0/16"]
  dns_label      = "minecraft"
}

resource "oci_core_internet_gateway" "minecraft" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.minecraft.id
  display_name   = "minecraft-igw"
  enabled        = true
}

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.minecraft.id
  display_name   = "minecraft-public-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.minecraft.id
  }
}

resource "oci_core_security_list" "public" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.minecraft.id
  display_name   = "minecraft-public-sl"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  ingress_security_rules {
    description = "SSH do administrador"
    source      = var.admin_cidr
    protocol    = "6"
    tcp_options {
      min = 22
      max = 22
    }
  }

  ingress_security_rules {
    description = "Minecraft Java"
    source      = "0.0.0.0/0"
    protocol    = "6"
    tcp_options {
      min = var.minecraft_port
      max = var.minecraft_port
    }
  }

  ingress_security_rules {
    description = "Path MTU discovery"
    source      = "0.0.0.0/0"
    protocol    = "1"
    icmp_options {
      type = 3
      code = 4
    }
  }
}

resource "oci_core_subnet" "public" {
  compartment_id    = var.compartment_id
  vcn_id            = oci_core_vcn.minecraft.id
  display_name      = "minecraft-public"
  cidr_block        = "10.0.1.0/24"
  dns_label         = "public"
  route_table_id    = oci_core_route_table.public.id
  security_list_ids = [oci_core_security_list.public.id]
}
