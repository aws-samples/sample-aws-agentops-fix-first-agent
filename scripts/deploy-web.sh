#!/bin/bash
# Full deployment script for the FixFirst static web application.
# 1. Generates config.js from SSM parameters (written by AgentCoreStack)
# 2. Deploys the WebHosting stack (S3 + CloudFront)
# 3. Re-deploys AgentCore stack with CloudFront URL for Cognito callback URLs
#
# Prerequisites: AgentCore stack must be deployed first (fixFirstAgent/cdk)
#
# Usage: ./scripts/deploy-web.sh

set -euo pipefail

# Prevent Git Bash (MSYS) from converting /forward-slash arguments to Windows paths
export MSYS_NO_PATHCONV=1

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

echo "=== Step 1: Generate config.js from SSM parameters ==="
bash scripts/generate-config.sh "${APP_NAME}"

echo ""
echo "=== Step 2: Deploy WebHosting stack (S3 + CloudFront) ==="
cd cdk
npm install
npx cdk deploy fixFirstAgent-WebHostingStack --require-approval never
cd ..

echo ""
echo "=== Step 3: Retrieve CloudFront URL ==="
CF_URL=$(aws ssm get-parameter --name "/${APP_NAME}/cloudfront-url" --region "${DEPLOY_REGION}" --query 'Parameter.Value' --output text 2>/dev/null || echo "")
if [ -z "${CF_URL}" ]; then
  echo "CloudFront URL not found in SSM. Check the WebHosting stack deployment."
  exit 1
fi
echo "CloudFront URL: ${CF_URL}"

echo ""
echo "=== Step 4: Update AgentCore stack with CloudFront callback URL ==="
cd fixFirstAgent/cdk
npm install
npx cdk deploy fixFirstAgent-AgentCoreStack --require-approval never \
  -c cloudfrontUrl="${CF_URL}"
cd ../..

echo ""
echo "=== Deployment complete ==="
echo "Website URL: ${CF_URL}"
