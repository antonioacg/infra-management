# Terraform Backend Configuration Template
# This will be populated by the bootstrap script with actual credentials

bucket                      = "terraform-state"
key                        = "bootstrap/terraform.tfstate"
region                     = "us-east-1"
endpoint                   = "http://localhost:9000"
access_key                 = "PLACEHOLDER_ACCESS_KEY"
secret_key                 = "PLACEHOLDER_SECRET_KEY"
force_path_style          = true
skip_credentials_validation = true
skip_metadata_api_check    = true
skip_region_validation     = true