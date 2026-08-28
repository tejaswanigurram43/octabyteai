#!/usr/bin/env bash
# scripts/deploy.sh
# ─────────────────────────────────────────────────────────────────────────────
# Manual deployment helper script.
# Builds & pushes the Docker image to ECR, then updates the ECS service.
#
# Usage:
#   bash scripts/deploy.sh --env staging --tag <IMAGE_TAG>
#   bash scripts/deploy.sh --env production --tag v1.2.3
#
# Prerequisites: aws CLI v2, docker, jq
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
ENVIRONMENT="staging"
IMAGE_TAG="$(git rev-parse --short HEAD 2>/dev/null || echo 'latest')"
AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT="octabyteai"
SKIP_PUSH=false
WAIT_FOR_STABLE=true

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env|-e)         ENVIRONMENT="$2"; shift 2 ;;
    --tag|-t)         IMAGE_TAG="$2"; shift 2 ;;
    --region)         AWS_REGION="$2"; shift 2 ;;
    --skip-push)      SKIP_PUSH=true; shift ;;
    --no-wait)        WAIT_FOR_STABLE=false; shift ;;
    -h|--help)
      echo "Usage: $0 [--env ENV] [--tag TAG] [--region REGION] [--skip-push] [--no-wait]"
      exit 0 ;;
    *) error "Unknown argument: $1" ;;
  esac
done

[[ "$ENVIRONMENT" =~ ^(staging|production)$ ]] \
  || error "Environment must be 'staging' or 'production'"

ECS_CLUSTER="${PROJECT}-${ENVIRONMENT}-cluster"
ECS_SERVICE="${PROJECT}-${ENVIRONMENT}-service"
TASK_FAMILY="${PROJECT}-${ENVIRONMENT}-app"
CONTAINER_NAME="${PROJECT}-app"

# ── Get ECR registry URL ───────────────────────────────────────────────────────
info "Getting ECR registry URL..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
ECR_REPO="${ECR_REGISTRY}/${PROJECT}-app"
FULL_IMAGE="${ECR_REPO}:${IMAGE_TAG}"

info "Environment:  ${ENVIRONMENT}"
info "Image:        ${FULL_IMAGE}"
info "ECS Cluster:  ${ECS_CLUSTER}"
info "ECS Service:  ${ECS_SERVICE}"

# ── Build & Push ──────────────────────────────────────────────────────────────
if ! $SKIP_PUSH; then
  info "Logging in to ECR..."
  aws ecr get-login-password --region "${AWS_REGION}" \
    | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

  info "Building Docker image (linux/amd64)..."
  docker buildx build \
    --platform linux/amd64 \
    --tag "${FULL_IMAGE}" \
    --tag "${ECR_REPO}:latest" \
    ./app

  info "Pushing image to ECR..."
  docker push "${FULL_IMAGE}"
  docker push "${ECR_REPO}:latest"
  info "Image pushed: ${FULL_IMAGE}"
fi

# ── Get current task definition ───────────────────────────────────────────────
info "Fetching current task definition..."
TASK_DEF_JSON=$(aws ecs describe-task-definition \
  --task-definition "${TASK_FAMILY}" \
  --region "${AWS_REGION}" \
  --query 'taskDefinition' \
  --output json)

# ── Update container image in task definition ──────────────────────────────────
info "Creating new task definition revision..."
NEW_TASK_DEF=$(echo "${TASK_DEF_JSON}" | jq \
  --arg IMAGE "${FULL_IMAGE}" \
  --arg CONTAINER "${CONTAINER_NAME}" \
  '.containerDefinitions |= map(if .name == $CONTAINER then .image = $IMAGE else . end)
   | del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy)')

NEW_TASK_ARN=$(aws ecs register-task-definition \
  --cli-input-json "${NEW_TASK_DEF}" \
  --region "${AWS_REGION}" \
  --query 'taskDefinition.taskDefinitionArn' \
  --output text)

info "New task definition: ${NEW_TASK_ARN}"

# ── Update ECS service ─────────────────────────────────────────────────────────
info "Updating ECS service to use new task definition..."
aws ecs update-service \
  --cluster "${ECS_CLUSTER}" \
  --service "${ECS_SERVICE}" \
  --task-definition "${NEW_TASK_ARN}" \
  --region "${AWS_REGION}" \
  --force-new-deployment \
  --output json > /dev/null

# ── Wait for stability ────────────────────────────────────────────────────────
if $WAIT_FOR_STABLE; then
  info "Waiting for service to stabilize (this can take 2–5 minutes)..."
  aws ecs wait services-stable \
    --cluster "${ECS_CLUSTER}" \
    --services "${ECS_SERVICE}" \
    --region "${AWS_REGION}"
  info "Service is stable."
else
  warn "Skipping stability wait (--no-wait)"
fi

# ── Smoke test ────────────────────────────────────────────────────────────────
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names "${PROJECT}-${ENVIRONMENT}-alb" \
  --region "${AWS_REGION}" \
  --query 'LoadBalancers[0].DNSName' \
  --output text 2>/dev/null || echo "")

if [[ -n "${ALB_DNS}" ]]; then
  info "Running smoke test against http://${ALB_DNS}/health ..."
  for i in $(seq 1 5); do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://${ALB_DNS}/health" || echo "000")
    if [[ "${STATUS}" == "200" ]]; then
      info "Smoke test passed (HTTP 200)"
      break
    fi
    warn "Attempt ${i}: HTTP ${STATUS}, retrying in 10s..."
    sleep 10
  done
fi

info "Deployment complete: ${ENVIRONMENT} — ${FULL_IMAGE}"
