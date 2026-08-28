locals {
  prefix = "${var.project_name}-${var.environment}"
}

resource "aws_db_subnet_group" "main" {
  name       = "${local.prefix}-db-subnet-group"
  subnet_ids = var.subnet_ids

  tags = { Name = "${local.prefix}-db-subnet-group" }
}

resource "aws_db_parameter_group" "postgres15" {
  name   = "${local.prefix}-pg15"
  family = "postgres15"

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  parameter {
    name  = "log_duration"
    value = "1"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }
}

resource "aws_db_instance" "main" {
  identifier = "${local.prefix}-postgres"

  engine               = "postgres"
  engine_version       = "15.6"
  instance_class       = var.instance_class
  allocated_storage    = 20
  max_allocated_storage = 100
  storage_type         = "gp3"
  storage_encrypted    = true

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.security_group_id]
  parameter_group_name   = aws_db_parameter_group.postgres15.name

  multi_az               = var.multi_az
  publicly_accessible    = false
  deletion_protection    = var.environment == "production"
  skip_final_snapshot    = var.environment != "production"
  final_snapshot_identifier = var.environment == "production" ? "${local.prefix}-final-snapshot" : null

  backup_retention_period = var.environment == "production" ? 14 : 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:30-sun:05:30"

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true

  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_monitoring.arn

  tags = { Name = "${local.prefix}-postgres" }
}

# ── Enhanced Monitoring IAM Role ──────────────────────────────────────────────
resource "aws_iam_role" "rds_monitoring" {
  name = "${local.prefix}-rds-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}
