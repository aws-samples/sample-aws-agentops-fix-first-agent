#!/bin/bash
# run_eval.sh — Run batch evaluation on both PROD and PREPROD log groups.
#
# After shadow traffic has been flowing, this script evaluates both endpoints
# using the same evaluators so scores can be compared by promote.sh.
#
# Usage: bash run_eval.sh

set -euo pipefail

REGION=${REGION:-us-east-1}

RUNTIME_ARN=$(aws ssm get-parameter --name /fixFirstAgent/agentcore-runtime-arn --query Parameter.Value --output text --region "$REGION")
RUNTIME_ID=$(echo "$RUNTIME_ARN" | awk -F/ '{print $NF}')

PROD_LOG_GROUP="/aws/bedrock-agentcore/runtimes/${RUNTIME_ID}-PROD"
PREPROD_LOG_GROUP="/aws/bedrock-agentcore/runtimes/${RUNTIME_ID}-PREPROD"

EVALUATORS='[{"evaluatorId":"Builtin.Helpfulness"},{"evaluatorId":"Builtin.Correctness"},{"evaluatorId":"Builtin.Faithfulness"}]'
TIMESTAMP=$(date +%s)

echo "Starting batch evaluation on PROD..."
PROD_EVAL=$(aws bedrock-agentcore start-batch-evaluation \
    --batch-evaluation-name "prod_shadow_${TIMESTAMP}" \
    --evaluators "$EVALUATORS" \
    --data-source-config "{\"cloudWatchLogs\":{\"serviceNames\":[\"fixFirstAgent_Agent.PROD\"],\"logGroupNames\":[\"$PROD_LOG_GROUP\"]}}" \
    --region "$REGION" \
    --query 'batchEvaluationId' --output text)

echo "  PROD eval ID: $PROD_EVAL"

echo "Starting batch evaluation on PREPROD..."
PREPROD_EVAL=$(aws bedrock-agentcore start-batch-evaluation \
    --batch-evaluation-name "preprod_shadow_${TIMESTAMP}" \
    --evaluators "$EVALUATORS" \
    --data-source-config "{\"cloudWatchLogs\":{\"serviceNames\":[\"fixFirstAgent_Agent.PREPROD\"],\"logGroupNames\":[\"$PREPROD_LOG_GROUP\"]}}" \
    --region "$REGION" \
    --query 'batchEvaluationId' --output text)

echo "  PREPROD eval ID: $PREPROD_EVAL"

echo ""
echo "Both evaluations started. Run promote.sh to poll results and compare:"
echo "  bash promote.sh $PROD_EVAL $PREPROD_EVAL"
