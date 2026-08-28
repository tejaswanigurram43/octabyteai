#!/usr/bin/env bash
# scripts/run-migrations.sh
# ─────────────────────────────────────────────────────────────────────────────
# Runs SQL migrations against the target PostgreSQL database.
#
# Modes:
#   --local     Use local .env credentials via psql
#   (default)   Launch a one-off ECS Fargate task to run migrations in AWS
#
# Usage:
#   bash scripts/run-migrations.sh --local
#   bash scripts/run-migrations.sh --env staging
#
# Prerequisites: aws CLI v2, psql (local mode), jq
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ENVIRONMENT="staging"
LOCAL=false
MIGRATIONS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../app/src/migrations" && pwd)"
AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT="octabyteai"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)        LOCAL=true; shift ;;
    --env|-e)       ENVIRONMENT="$2"; shift 2 ;;
    --region)       AWS_REGION="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--local] [--env ENV] [--region REGION]"
      exit 0 ;;
    *) error "Unknown argument: $1" ;;
  esac
done

# ── Local mode ────────────────────────────────────────────────────────────────
if $LOCAL; then
  ENV_FILE="$(dirname "${BASH_SOURCE[0]}")/../app/.env"
  [[ -f "${ENV_FILE}" ]] || error ".env file not found at ${ENV_FILE}. Copy from .env.example first."

  # shellcheck disable=SC1090
  source "${ENV_FILE}"

  DB_HOST="${DB_HOST:-localhost}"
  DB_PORT="${DB_PORT:-5432}"
  DB_NAME="${DB_NAME:-octabyteai}"
  DB_USER="${DB_USER:-postgres}"
  PGPASSWORD="${DB_PASSWORD:-postgres}"
  export PGPASSWORD

  info "Running migrations locally against ${DB_HOST}:${DB_PORT}/${DB_NAME}..."

  MIGRATION_FILES=$(find "${MIGRATIONS_DIR}" -name "*.sql" | sort)
  [[ -z "${MIGRATION_FILES}" ]] && error "No migration files found in ${MIGRATIONS_DIR}"

  # Create migrations tracking table if it doesn't exist
  psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c \
    "CREATE TABLE IF NOT EXISTS schema_migrations (version VARCHAR(64) PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW());" \
    2>/dev/null || true

  for FILE in ${MIGRATION_FILES}; do
    VERSION=$(basename "${FILE}" .sql)

    # Check if already applied
    APPLIED=$(psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" \
      -tAc "SELECT COUNT(*) FROM schema_migrations WHERE version = '${VERSION}';" 2>/dev/null || echo "0")

    if [[ "${APPLIED}" == "1" ]]; then
      info "Skipping (already applied): ${VERSION}"
      continue
    fi

    info "Applying migration: ${VERSION}"
    if psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" \
      --single-transaction -f "${FILE}"; then
      info "Migration applied: ${VERSION}"
    else
      error "Migration FAILED: ${VERSION} — rolling back"
    fi
  done

  info "All migrations complete."
  exit 0
fi

# ── AWS ECS one-off task mode ─────────────────────────────────────────────────
info "Running migrations via ECS Fargate one-off task in ${ENVIRONMENT}..."

CLUSTER="${PROJECT}-${ENVIRONMENT}-cluster"
TASK_FAMILY="${PROJECT}-${ENVIRONMENT}-app"

# Get the latest task definition ARN
TASK_DEF_ARN=$(aws ecs describe-task-definition \
  --task-definition "${TASK_FAMILY}" \
  --region "${AWS_REGION}" \
  --query 'taskDefinition.taskDefinitionArn' \
  --output text)

info "Using task definition: ${TASK_DEF_ARN}"

# Get private subnets and security group from the running service
SERVICE_DESC=$(aws ecs describe-services \
  --cluster "${CLUSTER}" \
  --services "${PROJECT}-${ENVIRONMENT}-service" \
  --region "${AWS_REGION}" \
  --query 'services[0]' \
  --output json)

SUBNETS=$(echo "${SERVICE_DESC}" | jq -r '.networkConfiguration.awsvpcConfiguration.subnets[]' \
  | tr '\n' ',' | sed 's/,$//')
SECURITY_GROUPS=$(echo "${SERVICE_DESC}" | jq -r '.networkConfiguration.awsvpcConfiguration.securityGroups[]' \
  | tr '\n' ',' | sed 's/,$//')

info "Launching migration task..."
TASK_ARN=$(aws ecs run-task \
  --cluster "${CLUSTER}" \
  --task-definition "${TASK_DEF_ARN}" \
  --launch-type FARGATE \
  --platform-version LATEST \
  --network-configuration \
    "awsvpcConfiguration={subnets=[${SUBNETS}],securityGroups=[${SECURITY_GROUPS}],assignPublicIp=DISABLED}" \
  --overrides '{
    "containerOverrides": [{
      "name": "'"${PROJECT}-app"'",
      "command": ["node", "src/migrate.js"]
    }]
  }' \
  --region "${AWS_REGION}" \
  --query 'tasks[0].taskArn' \
  --output text)

info "Migration task launched: ${TASK_ARN}"
info "Waiting for migration task to complete..."

aws ecs wait tasks-stopped \
  --cluster "${CLUSTER}" \
  --tasks "${TASK_ARN}" \
  --region "${AWS_REGION}"

# Check exit code
EXIT_CODE=$(aws ecs describe-tasks \
  --cluster "${CLUSTER}" \
  --tasks "${TASK_ARN}" \
  --region "${AWS_REGION}" \
  --query 'tasks[0].containers[0].exitCode' \
  --output text)

if [[ "${EXIT_CODE}" == "0" ]]; then
  info "Migration task completed successfully (exit code 0)"
else
  error "Migration task FAILED (exit code ${EXIT_CODE})"
fi
