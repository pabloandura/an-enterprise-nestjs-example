#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# deploy.sh — Deploy all CloudFormation stacks in dependency order.
#
# Usage:
#   ./infra/cloudformation/deploy.sh
#
# Prerequisites:
#   - AWS CLI v2 configured (aws configure)
#   - jq installed (brew install jq)
#   - The Secrets Manager secret for API env vars already created (see
#     aws-deployment-guide.md step 7). Set API_SECRET_ARN below.
#   - Docker images already pushed to ECR at least once (or use PLACEHOLDER
#     values and update after first push).
#
# What it does:
#   1. networking  — VPC, subnets, IGW, NAT, security groups
#   2. storage     — S3 bucket for uploads
#   3. databases   — RDS PostgreSQL + DocumentDB
#   4. compute     — ECR, IAM, ECS cluster, task defs, ALB, services
#
# Each stack is deployed with --capabilities CAPABILITY_NAMED_IAM so that
# CloudFormation can create IAM roles on your behalf.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Configuration — edit these before first run ──────────────────────────────

APP_NAME="nestjs-ecommerce"
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# ARN of the Secrets Manager secret created in step 7 of aws-deployment-guide.md
# Example: arn:aws:secretsmanager:us-east-1:123456789012:secret:nestjs-ecommerce/api/env-AbCdEf
API_SECRET_ARN="${API_SECRET_ARN:-REPLACE_WITH_YOUR_SECRET_ARN}"

# Passwords for the databases (must be at least 16 chars, no special characters)
# Generate with: openssl rand -base64 32 | tr -d '=+/' | cut -c1-24
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-REPLACE_WITH_POSTGRES_PASSWORD}"
DOCDB_PASSWORD="${DOCDB_PASSWORD:-REPLACE_WITH_DOCDB_PASSWORD}"

# ECR image URIs — filled automatically after stack 4 creates the repos.
# On first deploy, PLACEHOLDER values are used and you must push images + redeploy.
API_IMAGE_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${APP_NAME}/api:latest"
FRONTEND_IMAGE_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${APP_NAME}/frontend:latest"

# ── Helpers ───────────────────────────────────────────────────────────────────

STACK_DIR="$(cd "$(dirname "$0")" && pwd)"

deploy_stack() {
  local stack_name="$1"
  local template="$2"
  shift 2
  local params=("$@")

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Deploying: $stack_name"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  aws cloudformation deploy \
    --region "$AWS_REGION" \
    --stack-name "$stack_name" \
    --template-file "$template" \
    --capabilities CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset \
    "${params[@]+"${params[@]}"}"

  echo "  ✓ $stack_name deployed"
}

# ── Guard against unconfigured placeholders ───────────────────────────────────

if [[ "$API_SECRET_ARN" == "REPLACE_WITH_YOUR_SECRET_ARN" ]]; then
  echo "ERROR: Set API_SECRET_ARN before deploying compute stack."
  echo "       See aws-deployment-guide.md step 7."
  echo "       You can still deploy networking, storage, and databases first:"
  echo "         SKIP_COMPUTE=true ./infra/cloudformation/deploy.sh"
  echo ""
fi

# ── 1. Networking ─────────────────────────────────────────────────────────────

deploy_stack \
  "${APP_NAME}-networking" \
  "${STACK_DIR}/01-networking.yml" \
  --parameter-overrides AppName="$APP_NAME"

# ── 2. Storage ────────────────────────────────────────────────────────────────

deploy_stack \
  "${APP_NAME}-storage" \
  "${STACK_DIR}/02-storage.yml" \
  --parameter-overrides AppName="$APP_NAME"

# ── 3. Databases ──────────────────────────────────────────────────────────────

if [[ "$POSTGRES_PASSWORD" == "REPLACE_WITH_POSTGRES_PASSWORD" || \
      "$DOCDB_PASSWORD"    == "REPLACE_WITH_DOCDB_PASSWORD" ]]; then
  echo "WARNING: Database passwords are still placeholders."
  echo "         Generate them with: openssl rand -base64 32 | tr -d '=+/' | cut -c1-24"
  echo "         Then set POSTGRES_PASSWORD and DOCDB_PASSWORD env vars and re-run."
  echo "         Skipping database stack for now."
else
  deploy_stack \
    "${APP_NAME}-databases" \
    "${STACK_DIR}/03-databases.yml" \
    --parameter-overrides \
      AppName="$APP_NAME" \
      PostgresPassword="$POSTGRES_PASSWORD" \
      DocDbPassword="$DOCDB_PASSWORD"

  echo ""
  echo "  Database endpoints:"
  aws cloudformation describe-stacks \
    --region "$AWS_REGION" \
    --stack-name "${APP_NAME}-databases" \
    --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
    --output table
fi

# ── 4. Compute ────────────────────────────────────────────────────────────────

if [[ "${SKIP_COMPUTE:-false}" == "true" ]]; then
  echo ""
  echo "  Skipping compute stack (SKIP_COMPUTE=true)."
  echo "  After pushing images and creating the Secrets Manager secret, run:"
  echo "    API_SECRET_ARN=<arn> ./infra/cloudformation/deploy.sh"
else
  deploy_stack \
    "${APP_NAME}-compute" \
    "${STACK_DIR}/04-compute.yml" \
    --parameter-overrides \
      AppName="$APP_NAME" \
      ApiSecretArn="$API_SECRET_ARN" \
      ApiImageUri="$API_IMAGE_URI" \
      FrontendImageUri="$FRONTEND_IMAGE_URI"

  echo ""
  echo "  Compute outputs:"
  aws cloudformation describe-stacks \
    --region "$AWS_REGION" \
    --stack-name "${APP_NAME}-compute" \
    --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
    --output table

  ALB_DNS=$(aws cloudformation describe-stacks \
    --region "$AWS_REGION" \
    --stack-name "${APP_NAME}-compute" \
    --query 'Stacks[0].Outputs[?OutputKey==`AlbDnsName`].OutputValue' \
    --output text)

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  App is live at: http://${ALB_DNS}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi

# ── Post-deploy: print GitHub Actions secrets ─────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Add these to GitHub → Settings → Secrets → Actions"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AWS_ACCOUNT_ID       = ${AWS_ACCOUNT_ID}"
echo "  AWS_REGION           = ${AWS_REGION}"
echo "  ECR_REPO_API         = ${APP_NAME}/api"
echo "  ECR_REPO_FRONTEND    = ${APP_NAME}/frontend"
echo "  ECS_CLUSTER          = ${APP_NAME}-cluster"
echo "  ECS_SERVICE_API      = api"
echo "  ECS_SERVICE_FRONTEND = frontend"
echo "  ECS_TASK_FAMILY_API  = ${APP_NAME}-api"
echo "  ECS_TASK_FAMILY_FRONTEND = ${APP_NAME}-frontend"

if [[ "${SKIP_COMPUTE:-false}" != "true" ]]; then
  GITHUB_ROLE=$(aws cloudformation describe-stacks \
    --region "$AWS_REGION" \
    --stack-name "${APP_NAME}-compute" \
    --query 'Stacks[0].Outputs[?OutputKey==`GitHubActionsRoleArn`].OutputValue' \
    --output text 2>/dev/null || echo "(deploy compute stack first)")
  echo "  AWS_ROLE_ARN         = ${GITHUB_ROLE}"
fi
echo ""
