# Remote S3 backend configuration - partial config file
# Use with: terraform init -migrate-state -backend-config=backend-remote.hcl
#
# Usage:
#   terraform init -migrate-state \
#     -backend-config=backend-remote.hcl \
#     -backend-config="access_key=${TF_VAR_minio_access_key}" \
#     -backend-config="secret_key=${TF_VAR_minio_secret_key}" \
#     -backend-config="key=${ENVIRONMENT}/bootstrap/terraform.tfstate"
#
# Credentials are passed via -backend-config flags at runtime (not stored in this file)

bucket                      = "terraform-state"
key                         = "production/bootstrap/terraform.tfstate"
endpoint                    = "http://bootstrap-minio.bootstrap.svc.cluster.local:9000"
region                      = "us-east-1"
skip_credentials_validation = true
skip_metadata_api_check     = true
skip_region_validation      = true
skip_requesting_account_id  = true
force_path_style            = true
