#!/bin/bash
# Tear down ALL target-based A/B testing infrastructure.
#
# This script performs a complete cleanup in the correct order:
#   1. Stops and deletes the A/B test
#   2. Deletes gateway targets (control, treatment)
#   3. Deletes the gateway
#   4. Deletes the IAM role created by create_ab_test.py
#   5. Removes SSM parameters for gateway resources
#   6. Destroys fixFirstAgent-ABGatewayStack (CDK)
#   7. Destroys fixFirstAgent-ABTestingStack (CDK)
#
# Usage: ./cleanup_all.sh
#
# Environment variables (optional):
#   APP_NAME    — SSM parameter prefix (default: fixFirstAgent)
#   AWS_REGION  — AWS region (default: us-east-1)

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CDK_DIR="$(cd "${SCRIPT_DIR}/../cdk_ab_testing" && pwd)"
GW_CDK_DIR="$(cd "${SCRIPT_DIR}/../cdk_ab_gateway" && pwd)"

APP_NAME="${APP_NAME:-fixFirstAgent}"
REGION="${AWS_REGION:-us-east-1}"

echo "=== Target-Based A/B Testing Full Cleanup ==="
echo "Region: $REGION"
echo ""

# Step 1: Run the Python cleanup script (gateway, targets, A/B test, IAM role, SSM params)
echo "=== Step 1/2: Cleaning up gateway infrastructure ==="
python "${SCRIPT_DIR}/cleanup_ab_test.py"
echo ""

# Step 2: Destroy CDK stacks
echo "=== Step 2/2: Destroying CDK stacks ==="

echo "Destroying fixFirstAgent-ABGatewayStack..."
cd "$GW_CDK_DIR"
npx cdk destroy fixFirstAgent-ABGatewayStack --force 2>&1 || echo "  (stack may not exist, continuing)"

echo "Destroying fixFirstAgent-ABTestingStack..."
cd "$CDK_DIR"
npx cdk destroy fixFirstAgent-ABTestingStack --force 2>&1 || echo "  (stack may not exist, continuing)"

echo ""
echo "=== Cleanup Complete ==="
echo "All target-based A/B testing infrastructure has been removed."
