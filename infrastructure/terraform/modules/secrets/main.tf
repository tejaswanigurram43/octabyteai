locals {
  prefix = "${var.project_name}-${var.environment}"
}

# ── KMS Customer Managed Key ───────────────────────────────────────────────────
resource "aws_kms_key" "main" {
  description             = "${local.prefix} encryption key"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_alias" "main" {
  name          = "alias/${local.prefix}"
  target_key_id = aws_kms_key.main.key_id
}

# ── Random Database Password ───────────────────────────────────────────────────
resource "random_password" "db" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# ── Secrets Manager Secret ─────────────────────────────────────────────────────
resource "aws_secretsmanager_secret" "db" {
  name        = "${local.prefix}/db-credentials"
  description = "RDS PostgreSQL credentials for ${local.prefix}"
  kms_key_id  = aws_kms_key.main.arn

  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
    dbname   = var.db_name
    engine   = "postgres"
    port     = 5432
  })
}

# ── IAM Policy for accessing secret ───────────────────────────────────────────
resource "aws_iam_policy" "db_secret_access" {
  name        = "${local.prefix}-db-secret-access"
  description = "Allow reading the DB credentials secret"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.db.arn
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = aws_kms_key.main.arn
      }
    ]
  })
}
