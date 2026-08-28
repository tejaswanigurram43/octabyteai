output "vpc_id" {
  description = "ID of the VPC"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "IDs of the private subnets"
  value       = module.vpc.private_subnet_ids
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = module.alb.alb_dns_name
}

output "alb_zone_id" {
  description = "Route 53 Zone ID of the ALB (for alias records)"
  value       = module.alb.alb_zone_id
}

output "rds_endpoint" {
  description = "Endpoint of the RDS PostgreSQL instance"
  value       = module.rds.db_endpoint
  sensitive   = true
}

output "rds_identifier" {
  description = "Identifier of the RDS instance"
  value       = module.rds.db_identifier
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster"
  value       = module.ecs.cluster_name
}

output "ecs_cluster_arn" {
  description = "ARN of the ECS cluster"
  value       = module.ecs.cluster_arn
}

output "ecs_service_name" {
  description = "Name of the ECS service"
  value       = module.ecs.service_name
}

output "ecr_repository_url" {
  description = "URL of the ECR repository"
  value       = aws_ecr_repository.app.repository_url
}

output "db_secret_arn" {
  description = "ARN of the Secrets Manager secret for DB credentials"
  value       = module.secrets.db_secret_arn
  sensitive   = true
}

output "cloudwatch_log_group_app" {
  description = "CloudWatch log group for application logs"
  value       = module.monitoring.log_group_app
}
