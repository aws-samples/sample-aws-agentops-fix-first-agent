#!/bin/bash
# Run the complete configuration-based A/B testing workflow end-to-end.
#
# This script performs all steps from the notebook in sequence:
#   1. Check prerequisites
#   2. Package the config-bundle agent
#   3. Deploy runtime + eval config (CDK)
#   4. Wait for runtime to become READY
#   5. Create config bundles + gateway + A/B test
#   6. Send traffic through the gateway
#   7. Wait for evaluation results
#   8. Print A/B test results
#
# Usage: ./run_config_ab_testing.sh
#
# Environment variables (optional):
#   APP_NAME         — SSM parameter prefix (default: fixFirstAgent)
#   AWS_REGION       — AWS region (default: from aws configure)
#   CONTROL_PROMPT   — system prompt for control variant
#   TREATMENT_PROMPT — system prompt for treatment variant

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AB_DIR="${SCRIPT_DIR}"
CONFIG_DIR="${AB_DIR}/configuration_based_variants"
CONFIG_SCRIPTS="${CONFIG_DIR}/scripts"

APP_NAME="${APP_NAME:-fixFirstAgent}"
REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo us-east-1)}"

echo "============================================================"
echo "  Configuration Bundle A/B Testing - End-to-End"
echo "============================================================"
echo "Region: $REGION"
echo ""

# === Step 1: Check prerequisites ===
echo "=== Step 1/7: Checking prerequisites ==="
bash "${AB_DIR}/scripts/check_prerequisites.sh"
echo ""

# === Step 2: Package agent ===
echo "=== Step 2/7: Packaging config-bundle agent ==="
bash "${CONFIG_SCRIPTS}/package_config_agent.sh" "${CONFIG_DIR}/agent"
echo ""

# === Step 3: Deploy runtime + eval config ===
echo "=== Step 3/7: Deploying runtime + eval config ==="
bash "${CONFIG_SCRIPTS}/deploy_config_agent.sh" "${CONFIG_DIR}/cdk"
echo ""

# === Step 4: Wait for runtime to become READY ===
echo "=== Step 4/7: Waiting for runtime to become READY ==="
RUNTIME_ARN=$(aws ssm get-parameter --name "/${APP_NAME}/config-runtime-arn" --query Parameter.Value --output text --region "$REGION")
RUNTIME_ID=$(echo "$RUNTIME_ARN" | awk -F/ '{print $NF}')

echo "Waiting for ${RUNTIME_ID}..."
for i in $(seq 1 30); do
    STATUS=$(aws bedrock-agentcore-control get-agent-runtime --agent-runtime-id "$RUNTIME_ID" --region "$REGION" --query status --output text 2>/dev/null || echo "UNKNOWN")
    if [ "$STATUS" = "READY" ]; then
        echo "  READY"
        break
    fi
    echo "  [${i}/30] ${STATUS}"
    sleep 20
done
if [ "$STATUS" != "READY" ]; then
    echo "ERROR: Runtime not READY after 10 minutes"
    exit 1
fi
echo ""

# === Step 5: Create config bundles + gateway + A/B test ===
echo "=== Step 5/7: Creating config bundles + gateway + A/B test ==="
EXTRA_ARGS=""
if [ -n "${CONTROL_PROMPT:-}" ]; then
    EXTRA_ARGS="$EXTRA_ARGS --control-prompt \"$CONTROL_PROMPT\""
fi
if [ -n "${TREATMENT_PROMPT:-}" ]; then
    EXTRA_ARGS="$EXTRA_ARGS --treatment-prompt \"$TREATMENT_PROMPT\""
fi
export AWS_REGION="$REGION"
export APP_NAME
eval python3 "${CONFIG_SCRIPTS}/create_config_ab_test.py" $EXTRA_ARGS
echo ""

# === Step 6: Send traffic ===
echo "=== Step 6/7: Sending traffic through gateway ==="
GATEWAY_URL=$(aws ssm get-parameter --name "/${APP_NAME}/config-ab-gateway-url" --query Parameter.Value --output text --region "$REGION")
bash "${AB_DIR}/scripts/send_traffic.sh" "$GATEWAY_URL" "$REGION" "${AB_DIR}/prompts.txt" "/fixfirst/invocations"
echo ""

# === Step 7: Wait and print results ===
echo "=== Step 7/7: Waiting for evaluation results ==="
echo "Results require ~15 minutes after sessions complete."
echo "Polling every 60 seconds..."
echo ""

AB_TEST_ID=$(aws ssm get-parameter --name "/${APP_NAME}/config-ab-test-id" --query Parameter.Value --output text --region "$REGION")

for i in $(seq 1 20); do
    SAMPLES=$(aws bedrock-agentcore get-ab-test --ab-test-id "$AB_TEST_ID" --region "$REGION" \
        --query "results.evaluatorMetrics[0].controlStats.sampleSize" --output text 2>/dev/null || echo "None")
    if [ "$SAMPLES" != "None" ] && [ -n "$SAMPLES" ]; then
        echo "Results available!"
        echo ""
        python3 "${AB_DIR}/scripts/check_ab_results.py" config-ab-test-id || \
        python "${AB_DIR}/scripts/check_ab_results.py" config-ab-test-id
        exit 0
    fi
    echo "  [${i}/20] No results yet, waiting 60s..."
    sleep 60
done

echo "WARNING: Results not available after 20 minutes. Run the check manually:"
echo "  python3 scripts/check_ab_results.py config-ab-test-id"
