#!/bin/bash
# promote.sh — Compare PROD vs PREPROD eval scores and promote if threshold met.
#
# Polls both batch evaluations until complete, then compares average scores.
# If PREPROD >= PROD (within allowed degradation threshold), promotes PREPROD version to PROD.
#
# Usage: bash promote.sh <prod_eval_id> <preprod_eval_id>

set -euo pipefail

REGION=${REGION:-us-east-1}
THRESHOLD=${THRESHOLD:-0.05}  # Allow up to 5% degradation

PROD_EVAL_ID=${1:?Usage: bash promote.sh <prod_eval_id> <preprod_eval_id>}
PREPROD_EVAL_ID=${2:?Usage: bash promote.sh <prod_eval_id> <preprod_eval_id>}

RUNTIME_ARN=$(aws ssm get-parameter --name /fixFirstAgent/agentcore-runtime-arn --query Parameter.Value --output text --region "$REGION")
RUNTIME_ID=$(echo "$RUNTIME_ARN" | awk -F/ '{print $NF}')

# Poll until evaluation completes
wait_for_eval() {
    local eval_id=$1
    local label=$2
    echo "Waiting for $label evaluation ($eval_id)..."
    while true; do
        STATUS=$(aws bedrock-agentcore get-batch-evaluation \
            --batch-evaluation-id "$eval_id" \
            --region "$REGION" \
            --query 'status' --output text)
        if [ "$STATUS" = "COMPLETED" ]; then
            echo "  $label: COMPLETED"
            return 0
        elif [ "$STATUS" = "FAILED" ]; then
            echo "  $label: FAILED"
            return 1
        fi
        echo "  $label: $STATUS (waiting 30s...)"
        sleep 30
    done
}

# Get average score across all evaluators
get_avg_score() {
    local eval_id=$1
    aws bedrock-agentcore get-batch-evaluation \
        --batch-evaluation-id "$eval_id" \
        --region "$REGION" \
        --query 'evaluationResults.evaluatorSummaries[].statistics.averageScore' --output json \
    | python3 -c "import sys,json; scores=json.load(sys.stdin); print(sum(scores)/len(scores) if scores else 0)"
}

# Wait for both evaluations
wait_for_eval "$PROD_EVAL_ID" "PROD" || { echo "PROD evaluation failed. Aborting."; exit 1; }
wait_for_eval "$PREPROD_EVAL_ID" "PREPROD" || { echo "PREPROD evaluation failed. Aborting."; exit 1; }

# Get scores
PROD_SCORE=$(get_avg_score "$PROD_EVAL_ID")
PREPROD_SCORE=$(get_avg_score "$PREPROD_EVAL_ID")

echo ""
echo "=== Evaluation Results ==="
echo "  PROD avg score:    $PROD_SCORE"
echo "  PREPROD avg score: $PREPROD_SCORE"
echo "  Threshold:         $THRESHOLD (max allowed degradation)"

# Compare: PREPROD must be >= PROD - threshold
PASS=$(python3 -c "
prod = $PROD_SCORE
preprod = $PREPROD_SCORE
threshold = $THRESHOLD
print('PASS' if preprod >= prod - threshold else 'FAIL')
")

echo "  Result:            $PASS"
echo ""

if [ "$PASS" = "FAIL" ]; then
    echo "PREPROD scored below threshold. Promotion BLOCKED."
    echo "PROD remains on its current version."
    exit 1
fi

# Promote: get PREPROD's current version and point PROD to it
PREPROD_VERSION=$(aws bedrock-agentcore-control get-agent-runtime-endpoint \
    --agent-runtime-id "$RUNTIME_ID" \
    --name "PREPROD" \
    --region "$REGION" \
    --query 'agentRuntimeVersion' --output text)

echo "Promoting PROD to version $PREPROD_VERSION..."
aws bedrock-agentcore-control update-agent-runtime-endpoint \
    --agent-runtime-id "$RUNTIME_ID" \
    --name "PROD" \
    --agent-runtime-version "$PREPROD_VERSION" \
    --region "$REGION" > /dev/null

echo "Done. PROD now points to version $PREPROD_VERSION."

# Show final state
echo ""
aws bedrock-agentcore-control list-agent-runtime-endpoints \
    --agent-runtime-id "$RUNTIME_ID" \
    --region "$REGION" \
    --output table \
    --query 'agentRuntimeEndpoints[].{Name:name,Version:agentRuntimeVersion,Status:status}'
