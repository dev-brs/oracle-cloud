# Trava preventiva: na tenancy inteira, só é possível criar o que cabe no Always Free.
# Dentro de uma mesma policy, a última instrução que casa prevalece, então primeiro
# zeramos a família toda e depois liberamos só o necessário.
resource "oci_limits_quota" "free_tier_only" {
  compartment_id = var.tenancy_ocid
  name           = "free-tier-only"
  description    = "Impede a criacao de recursos fora do Always Free"

  statements = [
    # Compute: só Ampere A1 (2 OCPU / 12 GB). Também bloqueia GPU, E4, E5, etc.
    "zero compute-core quotas in tenancy",
    "zero compute-memory quotas in tenancy",
    # A A1 é limitada em dois níveis (região e AD), e os dois precisam ser liberados.
    "set compute-core quota standard-a1-core-regional-count to 2 in tenancy",
    "set compute-memory quota standard-a1-memory-regional-count to 12 in tenancy",
    "set compute-core quota standard-a1-core-count to 2 in tenancy",
    "set compute-memory quota standard-a1-memory-count to 12 in tenancy",

    # Block storage: boot + block volumes somam no máximo 200 GB.
    "set block-storage quota total-storage-gb to 200 in tenancy",

    # Serviços pagos que este projeto não usa.
    "zero load-balancer quotas in tenancy",
    "zero database quotas in tenancy",
  ]
}
