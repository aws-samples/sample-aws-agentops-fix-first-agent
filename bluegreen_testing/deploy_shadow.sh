#!/bin/bash
# deploy_shadow.sh — Deploy the Shadow Traffic CDK stack.
#
# Deploys a Lambda + CloudWatch subscription filter that replays
# every PROD request to PREPROD automatically.
#
# Prerequisites:
#   - REGION, COGNITO_USERNAME, COGNITO_PASSWORD env vars set
#   - PREPROD endpoint exists and points to the new version
#   - Module 3 AgentCoreStack already deployed
#
# Usage: bash deploy_shadow.sh

set -euo pipefail

REGION=${REGION:-us-east-1}
HOME_DIR=${HOME_DIR:-~/sample-aws-agentops-fix-first-agent}
PASSWORD_PARAM="/fixFirstAgent/shadow-cognito-password"

if [ -z "${COGNITO_USERNAME:-}" ] || [ -z "${COGNITO_PASSWORD:-}" ]; then
    echo "ERROR: Set COGNITO_USERNAME and COGNITO_PASSWORD env vars."
    exit 1
fi

# Read runtime info from SSM (created by AgentCoreStack)
RUNTIME_ARN=$(aws ssm get-parameter --name /fixFirstAgent/agentcore-runtime-arn --query Parameter.Value --output text --region "$REGION")
RUNTIME_ID=$(echo "$RUNTIME_ARN" | awk -F/ '{print $NF}')
COGNITO_CLIENT_ID=$(aws ssm get-parameter --name /fixFirstAgent/cognito-client-id --query Parameter.Value --output text --region "$REGION")

echo "Runtime ID:       $RUNTIME_ID"
echo "Runtime ARN:      $RUNTIME_ARN"
echo "Cognito Client:   $COGNITO_CLIENT_ID"
echo "Cognito Username: $COGNITO_USERNAME"
echo "Shadow target:    PREPROD"
echo ""

# Store the Cognito password BEFORE deploying (so Lambda never reads a placeholder)
echo "Storing Cognito password in SSM SecureString..."
aws ssm put-parameter \
    --name "$PASSWORD_PARAM" \
    --value "$COGNITO_PASSWORD" \
    --type SecureString \
    --overwrite \
    --region "$REGION" > /dev/null

# Deploy the ShadowTrafficStack via CDK
echo ""
echo "Deploying ShadowTrafficStack..."
cd "$HOME_DIR/fixFirstAgent/cdk"

npx cdk deploy fixFirstAgent-ShadowTrafficStack --require-approval never \
    -c runtimeId="$RUNTIME_ID" \
    -c runtimeArn="$RUNTIME_ARN" \
    -c cognitoClientId="$COGNITO_CLIENT_ID" \
    -c cognitoUsername="$COGNITO_USERNAME"

echo ""
echo "Done. Shadow traffic is active."
echo "  Every prompt hitting PROD will be replayed to PREPROD automatically."
