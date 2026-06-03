#!/bin/bash
# Deploy the A/B testing gateway infrastructure: gateway + targets + A/B test.
# Usage: ./deploy_testing_infra.sh <cdk_dir>
#
# This script:
# 1. Reads runtime ARNs and eval ARNs from SSM (set by ABTestingStack)
# 2. Deploys the gateway stack (gateway, targets, A/B test via ILocalBundling)
#
# Prerequisites:
# - ABTestingStack must be deployed first (run deploy_agents.sh)

set -euo pipefail

CDK_DIR="${1:-.}"
APP_NAME="${APP_NAME:-fixFirstAgent}"
REGION="${AWS_REGION:-us-east-1}"

echo "Deploying A/B testing gateway infrastructure..."
cd "$CDK_DIR"

# Install CDK dependencies if needed
if [ ! -d "node_modules" ]; then
    echo "Installing CDK dependencies..."
    npm install
fi

# Read ARNs from SSM (set by ABTestingStack)
CONTROL_RUNTIME_ARN=$(aws ssm get-parameter --name "/${APP_NAME}/control-runtime-arn" --query Parameter.Value --output text --region "$REGION")
REFINED_RUNTIME_ARN=$(aws ssm get-parameter --name "/${APP_NAME}/refined-runtime-arn" --query Parameter.Value --output text --region "$REGION")
CONTROL_EVAL_ARN=$(aws ssm get-parameter --name "/${APP_NAME}/control-eval-arn" --query Parameter.Value --output text --region "$REGION")
TREATMENT_EVAL_ARN=$(aws ssm get-parameter --name "/${APP_NAME}/treatment-eval-arn" --query Parameter.Value --output text --region "$REGION")

echo "Control Runtime: $CONTROL_RUNTIME_ARN"
echo "Refined Runtime: $REFINED_RUNTIME_ARN"
echo "Control Eval: $CONTROL_EVAL_ARN"
echo "Treatment Eval: $TREATMENT_EVAL_ARN"

# Deploy gateway + targets + A/B test
echo "Starting CDK deploy (this may take 5-10 minutes with no output)..."
npx --yes cdk deploy fixFirstAgent-ABGatewayStack --require-approval never \
    -c "controlRuntimeArn=$CONTROL_RUNTIME_ARN" \
    -c "refinedRuntimeArn=$REFINED_RUNTIME_ARN" \
    -c "controlEvalArn=$CONTROL_EVAL_ARN" \
    -c "treatmentEvalArn=$TREATMENT_EVAL_ARN"

# Print results
GATEWAY_URL=$(aws ssm get-parameter --name "/${APP_NAME}/ab-gateway-url" --query Parameter.Value --output text --region "$REGION")
AB_TEST_ID=$(aws ssm get-parameter --name "/${APP_NAME}/ab-test-id" --query Parameter.Value --output text --region "$REGION")

echo ""
echo "=== A/B Testing Infrastructure Ready ==="
echo "Gateway URL: $GATEWAY_URL"
echo "A/B Test ID: $AB_TEST_ID"
echo "Traffic endpoint: ${GATEWAY_URL}/control/invocations"
