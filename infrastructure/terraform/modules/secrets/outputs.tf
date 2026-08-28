output "db_secret_arn" {
  value     = aws_secretsmanager_secret.db.arn
  sensitive = true
}

output "db_password" {
  value     = random_password.db.result
  sensitive = true
}

output "kms_key_arn" {
  value = aws_kms_key.main.arn
}

output "kms_key_id" {
  value = aws_kms_key.main.key_id
}

output "db_secret_access_policy_arn" {
  value = aws_iam_policy.db_secret_access.arn
}
