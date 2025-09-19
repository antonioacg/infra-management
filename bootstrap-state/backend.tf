# Bootstrap State Backend Configuration
# Initially uses local backend, then migrates to remote MinIO

terraform {
  # Start with local backend during bootstrap
  backend "local" {
    path = "terraform.tfstate"
  }

  # After MinIO is ready, migrate to remote backend with:
  # terraform init -migrate-state -backend-config=backend-remote.hcl
}