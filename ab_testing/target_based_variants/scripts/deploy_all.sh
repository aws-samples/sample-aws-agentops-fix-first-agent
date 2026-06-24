#!/bin/bash
# Deploy the complete target-based A/B testing infrastructure end-to-end.
#
# This script runs the full deployment pipeline:
#   1. Packages both agent variants for AgentCore Runtime (arm64 Linux)
#   2. Deploys runtimes + evaluation configs (fixFirstAgent-ABTestingStack)
#   3. Deploys gateway + targets + A/B test (fixFirstAgent-ABGatewayStack)
#
# After this script completes, the A/B test is running and ready to receive traffic.
#
# Usage: ./deploy_all.sh
#
# Environment variables (optional):
#   APP_NAME    — SSM parameter prefix (default: fixFirstAgent)
#   AWS_REGION  — AWS region (default: us-east-1)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CDK_DIR="$(cd "${SCRIPT_DIR}/../cdk_ab_testing" && pwd)"
GW_CDK_DIR="$(cd "${SCRIPT_DIR}/../cdk_ab_gateway" && pwd)"
AGENTS_DIR="$(cd "${SCRIPT_DIR}/../agents" && pwd)"

APP_NAME="${APP_NAME:-fixFirstAgent}"
REGION="${AWS_REGION:-us-east-1}"

echo "=== Target-Based A/B Testing Full Deployment ==="
echo "Region: $REGION"
echo "CDK Dir: $CDK_DIR"
echo "Agents Dir: $AGENTS_DIR"
echo ""

# Step 1: Package agents
echo "=== Step 1/3: Packaging agents ==="
bash "${SCRIPT_DIR}/package_agents.sh" "$AGENTS_DIR"
echo ""

# Step 2: Deploy runtimes + eval configs
echo "=== Step 2/3: Deploying runtimes + eval configs ==="
bash "${SCRIPT_DIR}/deploy_agents.sh" "$CDK_DIR"
echo ""

# Step 3: Deploy gateway + A/B test
echo "=== Step 3/3: Deploying gateway + A/B test ==="
bash "${SCRIPT_DIR}/deploy_testing_infra.sh" "$GW_CDK_DIR"
echo ""

echo "=== Deployment Complete ==="
GATEWAY_URL=$(aws ssm get-parameter --name "/${APP_NAME}/ab-gateway-url" --query Parameter.Value --output text --region "$REGION")
AB_TEST_ID=$(aws ssm get-parameter --name "/${APP_NAME}/ab-test-id" --query Parameter.Value --output text --region "$REGION")
echo "Gateway URL:      $GATEWAY_URL"
echo "A/B Test ID:      $AB_TEST_ID"
echo "Traffic endpoint: ${GATEWAY_URL}/control/invocations"
echo ""
echo "Send traffic to the endpoint above. Results appear ~15 min after sessions complete."
