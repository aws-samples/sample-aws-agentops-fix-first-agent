#!/bin/bash
# Tear down ALL configuration-based A/B testing infrastructure.
# Usage: ./cleanup_config_all.sh

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CDK_DIR="$(cd "${SCRIPT_DIR}/../cdk" && pwd)"

APP_NAME="${APP_NAME:-fixFirstAgent}"
REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo us-east-1)}"

echo "=== Config-Based A/B Testing Cleanup ==="
echo "Region: $REGION"
echo ""

# Step 1: Run Python cleanup (A/B test, bundles, gateway, IAM)
echo "=== Step 1/2: Cleaning up A/B test infrastructure ==="
python3 "${SCRIPT_DIR}/cleanup_config_ab_test.py" || python "${SCRIPT_DIR}/cleanup_config_ab_test.py"
echo ""

# Step 2: Destroy CDK stack
echo "=== Step 2/2: Destroying CDK stack ==="
cd "$CDK_DIR"
npx cdk destroy fixFirstAgent-ConfigABTestingStack --force 2>&1 || echo "  (stack may not exist, continuing)"

echo ""
echo "=== Cleanup Complete ==="
