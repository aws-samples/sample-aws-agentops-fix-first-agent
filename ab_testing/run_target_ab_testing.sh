#!/bin/bash
# Run the complete target-based A/B testing workflow end-to-end.
#
# This script performs all steps from the notebook in sequence:
#   1. Check prerequisites
#   2. Package agents
#   3. Deploy runtimes + eval configs (CDK)
#   4. Deploy gateway + targets + A/B test (CDK)
#   5. Wait for runtimes to become READY
#   6. Send traffic through the gateway
#   7. Wait for evaluation results
#   8. Print A/B test results
#
# Usage: ./run_target_ab_testing.sh
#
# Environment variables (optional):
#   APP_NAME    — SSM parameter prefix (default: fixFirstAgent)
#   AWS_REGION  — AWS region (default: us-east-1)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AB_DIR="${SCRIPT_DIR}"
TARGET_DIR="${AB_DIR}/target_based_variants"
TARGET_SCRIPTS="${TARGET_DIR}/scripts"

APP_NAME="${APP_NAME:-fixFirstAgent}"
REGION="${AWS_REGION:-us-east-1}"

echo "============================================================"
echo "  Target-Based A/B Testing - End-to-End"
echo "============================================================"
echo "Region: $REGION"
echo ""

# === Step 1: Check prerequisites ===
echo "=== Step 1/7: Checking prerequisites ==="
bash "${AB_DIR}/scripts/check_prerequisites.sh"
echo ""

# === Step 2: Package agents ===
echo "=== Step 2/7: Packaging agents ==="
bash "${TARGET_SCRIPTS}/package_agents.sh" "${TARGET_DIR}/agents"
echo ""

# === Step 3: Deploy runtimes + eval configs ===
echo "=== Step 3/7: Deploying runtimes + eval configs ==="
bash "${TARGET_SCRIPTS}/deploy_agents.sh" "${TARGET_DIR}/cdk_ab_testing"
echo ""

# === Step 4: Deploy gateway + A/B test ===
echo "=== Step 4/7: Deploying gateway + targets + A/B test ==="
bash "${TARGET_SCRIPTS}/deploy_testing_infra.sh" "${TARGET_DIR}/cdk_ab_gateway"
echo ""

# === Step 5: Wait for runtimes to become READY ===
echo "=== Step 5/7: Waiting for runtimes to become READY ==="
CONTROL_ARN=$(aws ssm get-parameter --name "/${APP_NAME}/control-runtime-arn" --query Parameter.Value --output text --region "$REGION")
REFINED_ARN=$(aws ssm get-parameter --name "/${APP_NAME}/refined-runtime-arn" --query Parameter.Value --output text --region "$REGION")

for RUNTIME_ARN in "$CONTROL_ARN" "$REFINED_ARN"; do
    RID=$(echo "$RUNTIME_ARN" | awk -F/ '{print $NF}')
    echo "Waiting for ${RID}..."
    for i in $(seq 1 30); do
        STATUS=$(aws bedrock-agentcore-control get-agent-runtime --agent-runtime-id "$RID" --region "$REGION" --query status --output text 2>/dev/null || echo "UNKNOWN")
        if [ "$STATUS" = "READY" ]; then
            echo "  READY"
            break
        fi
        echo "  [${i}/30] ${STATUS}"
        sleep 20
    done
    if [ "$STATUS" != "READY" ]; then
        echo "ERROR: Runtime ${RID} not READY after 10 minutes"
        exit 1
    fi
done
echo ""

# === Step 6: Send traffic ===
echo "=== Step 6/7: Sending traffic through gateway ==="
GATEWAY_URL=$(aws ssm get-parameter --name "/${APP_NAME}/ab-gateway-url" --query Parameter.Value --output text --region "$REGION")
bash "${AB_DIR}/scripts/send_traffic.sh" "$GATEWAY_URL" "$REGION" "${AB_DIR}/prompts.txt"
echo ""

# === Step 7: Wait and print results ===
echo "=== Step 7/7: Waiting for evaluation results ==="
echo "Results require ~15 minutes after sessions complete."
echo "Polling every 60 seconds..."
echo ""

AB_TEST_ID=$(aws ssm get-parameter --name "/${APP_NAME}/ab-test-id" --query Parameter.Value --output text --region "$REGION")

for i in $(seq 1 20); do
    SAMPLES=$(aws bedrock-agentcore get-ab-test --ab-test-id "$AB_TEST_ID" --region "$REGION" \
        --query "results.evaluatorMetrics[0].controlStats.sampleSize" --output text 2>/dev/null || echo "None")
    if [ "$SAMPLES" != "None" ] && [ -n "$SAMPLES" ]; then
        echo "Results available! Fetching..."
        echo ""
        echo "============================================================"
        echo "  A/B TEST RESULTS"
        echo "============================================================"
        aws bedrock-agentcore get-ab-test --ab-test-id "$AB_TEST_ID" --region "$REGION" \
            --query "{Status:status,Execution:executionStatus,AnalysisTime:results.analysisTimestamp,Control:{Mean:results.evaluatorMetrics[0].controlStats.mean,Samples:results.evaluatorMetrics[0].controlStats.sampleSize},Treatment:{Mean:results.evaluatorMetrics[0].variantResults[0].mean,Samples:results.evaluatorMetrics[0].variantResults[0].sampleSize,PercentChange:results.evaluatorMetrics[0].variantResults[0].percentChange,PValue:results.evaluatorMetrics[0].variantResults[0].pValue,Significant:results.evaluatorMetrics[0].variantResults[0].isSignificant}}" \
            --output table
        echo "============================================================"
        echo ""
        echo "Full JSON:"
        aws bedrock-agentcore get-ab-test --ab-test-id "$AB_TEST_ID" --region "$REGION" --query results --output json
        exit 0
    fi
    echo "  [${i}/20] No results yet, waiting 60s..."
    sleep 60
done

echo "WARNING: Results not available after 20 minutes. Run the check manually:"
echo "  aws bedrock-agentcore get-ab-test --ab-test-id ${AB_TEST_ID} --region ${REGION}"
