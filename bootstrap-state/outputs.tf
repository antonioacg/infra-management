# Bootstrap State Outputs

output "minio_endpoint" {
  description = "MinIO endpoint for Terraform state backend"
  value       = "http://bootstrap-minio.bootstrap.svc.cluster.local:9000"
}

output "minio_external_endpoint" {
  description = "MinIO endpoint accessible via port-forward"
  value       = "http://localhost:9000"
}

output "postgresql_endpoint" {
  description = "PostgreSQL endpoint for state locking"
  value       = "bootstrap-postgresql.bootstrap.svc.cluster.local:5432"
}

output "state_bucket" {
  description = "S3 bucket for Terraform state"
  value       = "terraform-state"
}

output "vault_bucket" {
  description = "S3 bucket for Vault storage"
  value       = "vault-storage"
}

output "bootstrap_namespace" {
  description = "Bootstrap namespace"
  value       = kubernetes_namespace.bootstrap.metadata[0].name
}