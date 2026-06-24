#!/bin/bash
# Fetch online evaluation scores from CloudWatch Metrics.
# Usage: bash check_online_eval.sh

set -euo pipefail

REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo us-east-1)}"
SERVICE="fixFirstAgent_Agent.DEFAULT"
START=$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-2H +%Y-%m-%dT%H:%M:%SZ)
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "=== Online Evaluation Results ==="
echo "Service: $SERVICE"
echo "Period:  $START → $END"
echo
printf "%-30s %s\n" "Evaluator" "Avg Score"
printf "%-30s %s\n" "------------------------------" "---------"

for METRIC in Builtin.Helpfulness Builtin.Correctness Builtin.ResponseRelevance; do
    SCORE=$(aws cloudwatch get-metric-statistics \
        --namespace "Bedrock-AgentCore/Evaluations" \
        --metric-name "$METRIC" \
        --dimensions Name=service.name,Value=$SERVICE \
        --start-time "$START" --end-time "$END" \
        --period 7200 --statistics Average \
        --region "$REGION" --output text \
        --query 'Datapoints[0].Average' 2>/dev/null || echo "N/A")
    printf "%-30s %s\n" "$METRIC" "$SCORE"
done
