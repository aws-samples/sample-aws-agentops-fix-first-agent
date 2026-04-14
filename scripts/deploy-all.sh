#!/bin/bash
# End-to-end deployment for the entire FixFirst platform.
#
# Order:
#   1. Package agent code + Python dependencies into a zip-ready directory
#   2. Deploy AgentCore stack (zip-based, no Docker required)
#   3. Generate config.js from SSM parameters
#   4. Deploy WebHosting stack (S3 + CloudFront)
#   5. Retrieve CloudFront URL from SSM
#   6. Re-deploy AgentCore stack with CloudFront URL added to Cognito callback URLs
#
# Usage: ./scripts/deploy-all.sh

set -euo pipefail

# Prevent Git Bash (MSYS) from converting /forward-slash arguments to Windows paths
export MSYS_NO_PATHCONV=1

# Always run from the repo root, regardless of where the script is invoked from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

APP_NAME="fixFirstAgent"

# Determine the AWS region consistently for all CLI calls
if [ -n "${AWS_REGION:-}" ]; then
  DEPLOY_REGION="${AWS_REGION}"
elif [ -n "${AWS_DEFAULT_REGION:-}" ]; then
  DEPLOY_REGION="${AWS_DEFAULT_REGION}"
else
  DEPLOY_REGION=$(aws configure get region 2>/dev/null || echo "us-west-2")
fi
export AWS_REGION="${DEPLOY_REGION}"
echo "Using AWS region: ${DEPLOY_REGION}"

echo "============================================"
echo "  FixFirst Agent — Full Deployment"
echo "============================================"

echo ""
echo "=== Step 1: Package agent code + dependencies ==="
bash scripts/package-agent.sh

echo ""
echo "=== Step 2: Deploy AgentCore stack (zip-based, no Docker required) ==="
cd fixFirstAgent/cdk
npm install
npx cdk deploy fixFirstAgent-AgentCoreStack --require-approval never
cd ../..

# Quick sanity check: verify the SSM parameters were created
echo "Verifying AgentCore stack outputs..."
if ! aws ssm get-parameter --name "/${APP_NAME}/region" --region "${DEPLOY_REGION}" --query 'Parameter.Value' --output text >/dev/null 2>&1; then
  echo "WARNING: AgentCore SSM parameters not found immediately after deploy."
  echo "This may indicate the stack deployed to a different region than your CLI default."
  echo "CLI default region: $(aws configure get region 2>/dev/null || echo 'not set')"
fi

echo ""
echo "=== Step 3: Generate config.js from SSM parameters ==="
# On first deploy the AgentCore stack may still be stabilising and SSM
# parameters might not be queryable yet.  Retry a few times before giving up.
MAX_RETRIES=5
RETRY_DELAY=10
for i in $(seq 1 $MAX_RETRIES); do
  if aws ssm get-parameter --name "/${APP_NAME}/region" --region "${DEPLOY_REGION}" --query 'Parameter.Value' --output text >/dev/null 2>&1; then
    echo "SSM parameters available."
    break
  fi
  if [ "$i" -eq "$MAX_RETRIES" ]; then
    echo "ERROR: SSM parameters not found after ${MAX_RETRIES} attempts."
    echo "Verify that Step 2 (AgentCore stack) deployed successfully and that"
    echo "your AWS CLI default region matches the deployment region."
    exit 1
  fi
  echo "SSM parameters not yet available — retrying in ${RETRY_DELAY}s (attempt ${i}/${MAX_RETRIES})..."
  sleep $RETRY_DELAY
done
bash scripts/generate-config.sh "${APP_NAME}"

echo ""
echo "=== Step 4: Deploy WebHosting stack (S3 + CloudFront) ==="
cd cdk
npm install
npx cdk deploy fixFirstAgent-WebHostingStack --require-approval never
cd ..

echo ""
echo "=== Step 5: Retrieve CloudFront URL ==="
CF_URL=$(aws ssm get-parameter --name "/${APP_NAME}/cloudfront-url" --region "${DEPLOY_REGION}" --query 'Parameter.Value' --output text)
echo "CloudFront URL: ${CF_URL}"

echo ""
echo "=== Step 6: Re-deploy AgentCore stack with CloudFront callback URL ==="
cd fixFirstAgent/cdk
npx cdk deploy fixFirstAgent-AgentCoreStack --require-approval never \
  -c cloudfrontUrl="${CF_URL}"
cd ../..

echo ""
echo "============================================"
echo "  Deployment complete!"
echo "  Website: ${CF_URL}"
echo "============================================"
