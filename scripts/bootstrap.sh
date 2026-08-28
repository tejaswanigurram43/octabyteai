#!/usr/bin/env bash
# scripts/bootstrap.sh
# ─────────────────────────────────────────────────────────────────────────────
# Idempotent script to create AWS resources required before `terraform init`.
# Creates:
#   • S3 bucket for Terraform remote state (versioned, encrypted, private)
#   • DynamoDB table for state locking (PAY_PER_REQUEST billing)
#
# Usage:
#   bash scripts/bootstrap.sh [--dry-run] [--region REGION] [--profile PROFILE]
#
# Dependencies: aws CLI v2, jq (optional — for better output)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
PROFILE=""
DRY_RUN=false
PROJECT="octabyteai"
BUCKET_NAME="${PROJECT}-terraform-state"
TABLE_NAME="${PROJECT}-terraform-locks"

# ── Colour helpers ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
dry_run() { echo -e "${YELLOW}[DRY-RUN]${NC} Would run: $*"; }

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)           DRY_RUN=true; shift ;;
    --region)            REGION="$2"; shift 2 ;;
    --profile)           PROFILE="$2"; shift 2 ;;
    --bucket)            BUCKET_NAME="$2"; shift 2 ;;
    --table)             TABLE_NAME="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--dry-run] [--region REGION] [--profile PROFILE]"
      exit 0 ;;
    *) error "Unknown argument: $1" ;;
  esac
done

AWS_OPTS=""
[[ -n "$PROFILE" ]] && AWS_OPTS="--profile $PROFILE"

aws_cmd() {
  if $DRY_RUN; then
    dry_run "aws $*"
    return 0
  fi
  # shellcheck disable=SC2086
  aws $AWS_OPTS "$@"
}

# ── Verify AWS credentials ─────────────────────────────────────────────────────
info "Verifying AWS credentials..."
ACCOUNT_ID=$(aws $AWS_OPTS sts get-caller-identity --query Account --output text 2>/dev/null) \
  || error "AWS credentials not configured. Run 'aws configure' or set AWS_ACCESS_KEY_ID / AWS_ROLE_TO_ASSUME."
info "AWS Account: ${ACCOUNT_ID} | Region: ${REGION}"

# ── Create S3 bucket ──────────────────────────────────────────────────────────
info "Checking S3 bucket: ${BUCKET_NAME}..."

BUCKET_EXISTS=$(aws_cmd s3api head-bucket --bucket "${BUCKET_NAME}" 2>&1 || true)

if echo "${BUCKET_EXISTS}" | grep -q "404\|NoSuchBucket" || $DRY_RUN; then
  info "Creating S3 bucket: ${BUCKET_NAME}"

  if [[ "${REGION}" == "us-east-1" ]]; then
    aws_cmd s3api create-bucket \
      --bucket "${BUCKET_NAME}" \
      --region "${REGION}"
  else
    aws_cmd s3api create-bucket \
      --bucket "${BUCKET_NAME}" \
      --region "${REGION}" \
      --create-bucket-configuration LocationConstraint="${REGION}"
  fi

  # Enable versioning
  aws_cmd s3api put-bucket-versioning \
    --bucket "${BUCKET_NAME}" \
    --versioning-configuration Status=Enabled

  # Enable server-side encryption (AES-256)
  aws_cmd s3api put-bucket-encryption \
    --bucket "${BUCKET_NAME}" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

  # Block all public access
  aws_cmd s3api put-public-access-block \
    --bucket "${BUCKET_NAME}" \
    --public-access-block-configuration \
    'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'

  # Tag the bucket
  aws_cmd s3api put-bucket-tagging \
    --bucket "${BUCKET_NAME}" \
    --tagging "TagSet=[{Key=Project,Value=${PROJECT}},{Key=ManagedBy,Value=bootstrap-script}]"

  info "S3 bucket created successfully: ${BUCKET_NAME}"
else
  info "S3 bucket already exists: ${BUCKET_NAME}"
fi

# ── Create DynamoDB table ─────────────────────────────────────────────────────
info "Checking DynamoDB table: ${TABLE_NAME}..."

TABLE_STATUS=$(aws_cmd dynamodb describe-table \
  --table-name "${TABLE_NAME}" \
  --region "${REGION}" \
  --query 'Table.TableStatus' \
  --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "${TABLE_STATUS}" == "NOT_FOUND" ]] || $DRY_RUN; then
  info "Creating DynamoDB table: ${TABLE_NAME}"

  aws_cmd dynamodb create-table \
    --table-name "${TABLE_NAME}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${REGION}" \
    --tags Key=Project,Value="${PROJECT}" Key=ManagedBy,Value=bootstrap-script

  info "Waiting for DynamoDB table to become active..."
  if ! $DRY_RUN; then
    aws dynamodb wait table-exists \
      --table-name "${TABLE_NAME}" \
      --region "${REGION}" ${PROFILE:+--profile "$PROFILE"}
  fi
  info "DynamoDB table created successfully: ${TABLE_NAME}"
else
  info "DynamoDB table already exists: ${TABLE_NAME} (status: ${TABLE_STATUS})"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
info "Bootstrap complete!"
echo ""
echo "  S3 bucket:       ${BUCKET_NAME}"
echo "  DynamoDB table:  ${TABLE_NAME}"
echo "  AWS region:      ${REGION}"
echo ""
echo "Next steps:"
echo "  1. cd infrastructure/terraform"
echo "  2. cp terraform.tfvars.example terraform.tfvars"
echo "  3. Edit terraform.tfvars"
echo "  4. terraform init"
echo "  5. terraform plan -var-file=environments/staging.tfvars"
