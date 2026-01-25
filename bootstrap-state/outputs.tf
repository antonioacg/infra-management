# Bootstrap State Outputs

output "minio_endpoint" {
  description = "MinIO endpoint for Terraform state backend"
  value       = "http://minio.storage.svc.cluster.local:9000"
}

output "minio_external_endpoint" {
  description = "MinIO endpoint accessible via port-forward"
  value       = "http://localhost:9000"
}

output "postgresql_endpoint" {
  description = "PostgreSQL endpoint for state locking"
  value       = "postgresql-rw.databases.svc.cluster.local:5432"
}

output "state_bucket" {
  description = "S3 bucket for Terraform state"
  value       = "terraform-state"
}

output "vault_bucket" {
  description = "S3 bucket for Vault storage"
  value       = "vault-storage"
}

output "storage_namespace" {
  description = "Storage namespace (MinIO)"
  value       = kubernetes_namespace.storage.metadata[0].name
}

output "databases_namespace" {
  description = "Databases namespace (PostgreSQL)"
  value       = kubernetes_namespace.databases.metadata[0].name
}

output "minio_namespace" {
  description = "MinIO admin namespace (Vault credentials)"
  value       = kubernetes_namespace.minio.metadata[0].name
}
