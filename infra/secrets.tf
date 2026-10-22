# Secrets live in SSM Parameter Store (encrypted), not in the task definition.
# ECS injects them as env vars at startup using the execution role.
# Note: the values are still in terraform.tfstate, so never commit state files.
resource "aws_ssm_parameter" "database_uri" {
  name  = "/${var.project}/DATABASE_URI"
  type  = "SecureString"
  value = var.database_uri
}

resource "aws_ssm_parameter" "master_key" {
  name  = "/${var.project}/PARSE_MASTER_KEY"
  type  = "SecureString"
  value = var.parse_master_key
}
