#!/bin/bash
# Start a batch evaluation and poll until complete.
# Usage: bash run_batch_eval.sh

set -euo pipefail

REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo us-east-1)}"
RUNTIME_ARN=$(aws ssm get-parameter --name /fixFirstAgent/agentcore-runtime-arn --query Parameter.Value --output text --region "$REGION")
RUNTIME_ID=$(echo "$RUNTIME_ARN" | awk -F/ '{print $NF}')
LOG_GROUP="/aws/bedrock-agentcore/runtimes/${RUNTIME_ID}-DEFAULT"
EVAL_NAME="fixFirstAgent_batch_$(date +%s)"

echo "Runtime:   $RUNTIME_ID"
echo "Log group: $LOG_GROUP"
echo "Eval name: $EVAL_NAME"
echo

RESPONSE=$(aws bedrock-agentcore start-batch-evaluation \
    --batch-evaluation-name "$EVAL_NAME" \
    --evaluators '[{"evaluatorId":"Builtin.Helpfulness"},{"evaluatorId":"Builtin.Correctness"},{"evaluatorId":"Builtin.ResponseRelevance"}]' \
    --data-source-config '{"cloudWatchLogs":{"serviceNames":["fixFirstAgent_Agent.DEFAULT"],"logGroupNames":["'$LOG_GROUP'"]}}' \
    --region "$REGION" --output json)

BATCH_ID=$(echo "$RESPONSE" | python3 -c "import sys,json;print(json.load(sys.stdin)['batchEvaluationId'])")
echo "Started: $BATCH_ID"
echo "Polling for results..."
echo

while true; do
    STATUS=$(aws bedrock-agentcore get-batch-evaluation --batch-evaluation-id "$BATCH_ID" --region "$REGION" --output text --query status)
    echo "  Status: $STATUS"
    if [[ "$STATUS" == "COMPLETED" || "$STATUS" == "COMPLETED_WITH_ERRORS" || "$STATUS" == "FAILED" || "$STATUS" == "STOPPED" ]]; then
        break
    fi
    sleep 30
done

echo
echo "=== Results ==="
aws bedrock-agentcore get-batch-evaluation --batch-evaluation-id "$BATCH_ID" --region "$REGION" \
    --output table \
    --query 'evaluationResults.{Sessions:numberOfSessionsCompleted,Summaries:evaluatorSummaries[].{Evaluator:evaluatorId,AvgScore:statistics.averageScore,Evaluated:totalEvaluated,Failed:totalFailed}}'
