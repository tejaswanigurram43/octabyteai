# OctaByte AI — Production Infrastructure

[![CI](https://github.com/octabyteai/octabyteai/actions/workflows/ci.yml/badge.svg)](https://github.com/octabyteai/octabyteai/actions/workflows/ci.yml)
[![CD](https://github.com/octabyteai/octabyteai/actions/workflows/cd.yml/badge.svg)](https://github.com/octabyteai/octabyteai/actions/workflows/cd.yml)
[![Terraform](https://img.shields.io/badge/terraform-1.7%2B-7B42BC?logo=terraform)](https://www.terraform.io/)
[![Node.js](https://img.shields.io/badge/node-20%2B-339933?logo=node.js)](https://nodejs.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

End-to-end production infrastructure for OctaByte AI: AWS ECS Fargate application hosting, RDS PostgreSQL, Application Load Balancer, CloudWatch monitoring, and fully automated CI/CD via GitHub Actions.

---

## Architecture Overview

```
                          ┌─────────────────────────────────────────────┐
                          │                  AWS Region                  │
                          │                                               │
  Internet  ──HTTPS──►   │  ┌─────────────────────────────────────────┐ │
                          │  │        Application Load Balancer         │ │
                          │  │           (Public Subnets)               │ │
                          │  └──────────────────┬──────────────────────┘ │
                          │                     │                         │
                          │         ┌───────────▼───────────┐            │
                          │         │    Private Subnet A    │            │
                          │         │  ┌─────────────────┐  │            │
                          │         │  │  ECS Fargate    │  │            │
                          │         │  │  Task (app)     │  │            │
                          │         │  └────────┬────────┘  │            │
                          │         └───────────│───────────┘            │
                          │                     │                         │
                          │         ┌───────────▼───────────┐            │
                          │         │    Private Subnet B    │            │
                          │         │  ┌─────────────────┐  │            │
                          │         │  │  RDS PostgreSQL  │  │            │
                          │         │  │  (Multi-AZ prod) │  │            │
                          │         │  └─────────────────┘  │            │
                          │         └───────────────────────┘            │
                          │                                               │
                          │  ┌──────────────┐  ┌──────────────────────┐  │
                          │  │  Secrets     │  │   CloudWatch         │  │
                          │  │  Manager     │  │   Logs / Alarms /    │  │
                          │  │  (KMS enc.)  │  │   Dashboards (x2)    │  │
                          │  └──────────────┘  └──────────────────────┘  │
                          │                                               │
                          │  ┌──────────────┐  ┌──────────────────────┐  │
                          │  │  ECR         │  │   NAT Gateways       │  │
                          │  │  Repository  │  │   (1 per AZ)         │  │
                          │  └──────────────┘  └──────────────────────┘  │
                          └─────────────────────────────────────────────┘
```

---

## Quick Start

### Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| [AWS CLI](https://aws.amazon.com/cli/) | v2+ | AWS resource management |
| [Terraform](https://www.terraform.io/downloads) | 1.7+ | Infrastructure provisioning |
| [Docker](https://docs.docker.com/get-docker/) | 24+ | Container builds |
| [Node.js](https://nodejs.org/) | 20+ | Application runtime |
| [psql](https://www.postgresql.org/download/) | 15+ | Database migrations |

### 6-Step Setup

```bash
# 1. Clone the repository
git clone https://github.com/octabyteai/octabyteai.git && cd octabyteai

# 2. Bootstrap AWS remote state (run once)
bash scripts/bootstrap.sh

# 3. Configure Terraform variables
cp infrastructure/terraform/terraform.tfvars.example infrastructure/terraform/terraform.tfvars
# Edit terraform.tfvars — at minimum set alarm_email

# 4. Provision infrastructure
cd infrastructure/terraform
terraform init
terraform apply -var-file=environments/staging.tfvars

# 5. Start local development stack
cp app/.env.example app/.env
docker compose up -d

# 6. Run the app tests
cd app && npm ci && npm test
```

---

## Infrastructure Setup (Terraform)

### Bootstrap (once per AWS account)

```bash
# Create S3 bucket for Terraform state
aws s3api create-bucket \
  --bucket octabyteai-terraform-state \
  --region us-east-1

aws s3api put-bucket-versioning \
  --bucket octabyteai-terraform-state \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket octabyteai-terraform-state \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# Create DynamoDB table for state locking
aws dynamodb create-table \
  --table-name octabyteai-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

Or use the bootstrap script:

```bash
bash scripts/bootstrap.sh
```

### Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | `us-east-1` | AWS deployment region |
| `environment` | `staging` | `staging` or `production` |
| `project_name` | `octabyteai` | Resource naming prefix |
| `vpc_cidr` | `10.0.0.0/16` | VPC CIDR block |
| `db_instance_class` | `db.t3.micro` | RDS instance type |
| `ecs_task_cpu` | `256` | Fargate CPU units |
| `ecs_task_memory` | `512` | Fargate memory MiB |
| `desired_count` | `2` | Number of ECS tasks |
| `alarm_email` | — | SNS alarm notification email |
| `certificate_arn` | `""` | ACM cert ARN for HTTPS |
| `log_retention_days` | `30` | CloudWatch log retention |

### Terraform Workflow

```bash
cd infrastructure/terraform

# Staging
terraform init
terraform plan  -var-file=environments/staging.tfvars
terraform apply -var-file=environments/staging.tfvars

# Production
terraform plan  -var-file=environments/production.tfvars
terraform apply -var-file=environments/production.tfvars
```

### Key Outputs

After `terraform apply` completes:

```bash
terraform output alb_dns_name        # Application URL
terraform output ecr_repository_url  # ECR image push URL
terraform output rds_endpoint        # DB host (sensitive)
terraform output ecs_cluster_name    # ECS cluster name
terraform output db_secret_arn       # Secrets Manager ARN
```

---

## Application Deployment

### Local Development

```bash
# Start full stack (app + postgres + prometheus + grafana)
docker compose up -d

# View logs
docker compose logs -f app

# Application:  http://localhost:3000
# Prometheus:   http://localhost:9090
# Grafana:      http://localhost:3001  (admin / admin_local_password)
```

### Running Tests

```bash
cd app
npm ci
npm test                # unit tests
npm run test:coverage   # with coverage report
npm run lint            # ESLint
```

### Building & Pushing Docker Image

```bash
# Build
docker build -t octabyteai-app:latest ./app

# Push to ECR (replace with your account ID)
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS \
  --password-stdin 123456789012.dkr.ecr.us-east-1.amazonaws.com

docker tag  octabyteai-app:latest 123456789012.dkr.ecr.us-east-1.amazonaws.com/octabyteai-app:latest
docker push 123456789012.dkr.ecr.us-east-1.amazonaws.com/octabyteai-app:latest
```

### Database Migrations

```bash
# Local
bash scripts/run-migrations.sh --local

# Against ECS (via one-off Fargate task)
bash scripts/run-migrations.sh
```

---

## CI/CD Pipeline

### Required GitHub Secrets

| Secret | Used by | Description |
|--------|---------|-------------|
| `AWS_ROLE_TO_ASSUME` | `cd.yml`, `security.yml` | OIDC IAM role for deployments |
| `AWS_TERRAFORM_ROLE_ARN` | `terraform.yml` | OIDC IAM role for Terraform |
| `TF_STATE_BUCKET` | `terraform.yml` | S3 state bucket name |
| `TF_LOCK_TABLE` | `terraform.yml` | DynamoDB lock table name |
| `STAGING_URL` | `cd.yml` | Staging ALB URL for smoke tests |
| `SLACK_WEBHOOK_URL` | `cd.yml`, `security.yml` | Slack incoming webhook |
| `CODECOV_TOKEN` | `ci.yml` | Codecov upload token |
| `ECR_REGISTRY` | `security.yml` | ECR registry URL |

### Pipeline Stages

```
PR opened
   │
   ├─► [ci.yml]
   │       ├── test          (lint + unit tests + coverage + integration tests)
   │       ├── security-scan (npm audit + Trivy filesystem scan)
   │       └── docker-build-test (build image + /health smoke)
   │
Merge to main
   │
   ├─► [terraform.yml]  (only if infrastructure/terraform/** changed)
   │       └── terraform-apply (staging auto-approve)
   │
   └─► [cd.yml]
           ├── build-and-push     (Docker build + Trivy CRITICAL scan + ECR push)
           ├── deploy-staging     (ECS deploy + smoke test + Slack)
           └── deploy-production  (Manual approval required → ECS deploy + GitHub Release + Slack)

Every Monday 09:00 UTC
   └─► [security.yml]
           ├── npm-audit
           ├── trivy-ecr-scan
           ├── tfsec
           └── notify-slack
```

### Manual Approval for Production

Configure required reviewers under:  
**GitHub → Settings → Environments → production → Required reviewers**

---

## Monitoring & Dashboards

### CloudWatch Dashboards (2)

| Dashboard | URL Pattern | Contents |
|-----------|-------------|----------|
| Infrastructure Overview | `/cloudwatch/home?#dashboards:name=octabyteai-{env}-Infrastructure-Overview` | ECS CPU/Memory, RDS CPU/Connections/Storage, ALB Request Count |
| Application Overview | `/cloudwatch/home?#dashboards:name=octabyteai-{env}-Application-Overview` | HTTP 2xx/4xx/5xx, p50/p95/p99 latency, running task count, error count, healthy hosts |

### CloudWatch Alarms

| Alarm | Threshold | Action |
|-------|-----------|--------|
| ECS CPU High | > 80% for 10 min | SNS → Email |
| ECS Memory High | > 85% for 10 min | SNS → Email |
| RDS CPU High | > 80% for 10 min | SNS → Email |
| RDS Connections High | > 80 connections | SNS → Email |
| ALB 5xx Errors | > 10 in 5 min | SNS → Email |
| ALB p95 Latency | > 2s | SNS → Email |

### Grafana (Local)

```bash
docker compose up -d grafana
# Access: http://localhost:3001  (admin / admin_local_password)
```

Two pre-provisioned dashboards auto-load:
- **Infrastructure** — CPU, memory, disk, network, PostgreSQL connections
- **Application** — Request rate, error rate, p50/p95/p99 latency, active connections

---

## Security Considerations

### IAM Least Privilege
- ECS execution role: `AmazonECSTaskExecutionRolePolicy` + specific Secrets Manager `GetSecretValue`
- ECS task role: CloudWatch `PutLogEvents` only
- Terraform CI role: scoped to specific resource types via OIDC conditions
- No long-lived AWS access keys — all pipelines use GitHub OIDC

### Secrets Management
- Database credentials generated via `random_password` (32 chars, special chars)
- Stored in AWS Secrets Manager, encrypted with a KMS Customer Managed Key
- ECS containers receive credentials via `secrets:` block (never plain env vars)
- KMS key rotation enabled (`enable_key_rotation = true`)

### Network Isolation
- ECS tasks run in **private subnets** — no public IP
- RDS in **private subnets** — only reachable from app security group
- ALB in **public subnets** — internet-facing, forwards to private ECS tasks
- Security groups follow least-privilege: ALB → app (app port only), app → RDS (5432 only)
- VPC Flow Logs enabled → CloudWatch for network audit trail

### TLS / Encryption
- ALB HTTP listener redirects to HTTPS when `certificate_arn` is set
- TLS policy: `ELBSecurityPolicy-TLS13-1-2-2021-06` (TLS 1.3 preferred)
- RDS storage encrypted at rest (`storage_encrypted = true`)
- S3 buckets (ALB logs, Terraform state) use AES-256 server-side encryption
- Public access blocked on all S3 buckets

### Container Security
- Multi-stage Docker build — production image contains no dev dependencies
- Non-root user (`appuser`, UID 1000)
- Trivy vulnerability scan on every image push (CRITICAL = pipeline failure)
- Weekly Trivy scan of ECR image + tfsec on Terraform code
- ECR image scanning on push enabled

---

## Cost Optimization

### Right-Sizing
| Resource | Staging | Production | Notes |
|----------|---------|------------|-------|
| ECS CPU | 256 units (0.25 vCPU) | 512 units | Auto-scales to 10 tasks |
| ECS Memory | 512 MiB | 1024 MiB | Target-tracking autoscaling |
| RDS | `db.t3.micro` | `db.t3.small` | Scale to `r7g` under load |
| NAT Gateway | 1 per AZ | 1 per AZ | ~$32/month each |

### Fargate Spot
- Staging uses `FARGATE_SPOT` capacity provider (up to 70% cost reduction)
- Production uses `FARGATE` for availability guarantees

### CloudWatch Log Retention
- Staging: 7 days
- Production: 90 days
- VPC Flow Logs: 30 days (hardcoded — high volume)

### ECR Lifecycle Policy
- Retains only the 10 most recent images (prevents unbounded storage growth)

---

## Secret Management

Secrets are managed via **AWS Secrets Manager** with a KMS Customer Managed Key.

The DB credentials secret stores:

```json
{
  "username": "octabyteai_admin",
  "password": "<32-char random>",
  "dbname": "octabyteai",
  "engine": "postgres",
  "port": 5432
}
```

**Retrieve credentials (CLI):**

```bash
aws secretsmanager get-secret-value \
  --secret-id octabyteai-staging/db-credentials \
  --query SecretString \
  --output text | jq .
```

**KMS key rotation:** Automatic annual rotation is enabled on the CMK.

---

## Backup Strategy

### RDS Automated Backups

| Setting | Staging | Production |
|---------|---------|------------|
| Backup retention | 7 days | 14 days |
| Backup window | 03:00–04:00 UTC | 03:00–04:00 UTC |
| Multi-AZ | No | Yes |
| Deletion protection | No | **Yes** |
| Final snapshot | No | **Yes** |
| Point-in-time recovery | Yes | Yes |

**Restore from a point in time:**

```bash
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier octabyteai-production-postgres \
  --target-db-instance-identifier octabyteai-production-postgres-restored \
  --restore-time 2024-06-01T12:00:00Z
```

### Terraform State Versioning

S3 bucket versioning is enabled on the Terraform state bucket. Roll back to any previous state:

```bash
# List versions
aws s3api list-object-versions \
  --bucket octabyteai-terraform-state \
  --prefix octabyteai/terraform.tfstate

# Restore a version
aws s3api get-object \
  --bucket octabyteai-terraform-state \
  --key octabyteai/terraform.tfstate \
  --version-id <VERSION_ID> \
  terraform.tfstate.backup
```

---

## Troubleshooting

### ECS tasks fail to start
```bash
# Check service events
aws ecs describe-services \
  --cluster octabyteai-staging-cluster \
  --services octabyteai-staging-service \
  --query 'services[0].events[:5]'

# View task stopped reason
aws ecs describe-tasks \
  --cluster octabyteai-staging-cluster \
  --tasks <TASK_ARN> \
  --query 'tasks[0].stoppedReason'
```

### Application cannot connect to RDS
```bash
# Check security group rules
aws ec2 describe-security-groups \
  --filters Name=group-name,Values=octabyteai-staging-rds-sg

# Verify secret value
aws secretsmanager get-secret-value \
  --secret-id octabyteai-staging/db-credentials \
  --query SecretString --output text
```

### Terraform state lock stuck
```bash
# Force unlock (use with caution)
terraform force-unlock <LOCK_ID>
```

### ALB returns 502/503
```bash
# Check target health
aws elbv2 describe-target-health \
  --target-group-arn <TG_ARN>
```
