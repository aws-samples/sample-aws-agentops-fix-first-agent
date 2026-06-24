#!/bin/bash
# Operator-controlled failover script for FixFirst Agent multi-region setup.
#
# Usage:
#   ./scripts/failover.sh trigger [--region us-east-1]   # Failover to secondary
#   ./scripts/failover.sh restore [--region us-east-1]   # Return to primary
#   ./scripts/failover.sh status  [--region us-east-1]   # Check current state

set -euo pipefail

ACTION="${1:-}"
REGION="us-east-1"

shift || true

while [[ $# -gt 0 ]]; do
  case $1 in
    --region) REGION="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

NAMESPACE="FixFirstAgent/HealthCheck"
METRIC_NAME="Failover"
ALARM_NAME="fixFirstAgent-primary-failover-alarm"

case "${ACTION}" in
  trigger)
    echo "⚠️  Triggering failover — routing traffic to secondary region..."
    aws cloudwatch put-metric-data \
      --metric-name "${METRIC_NAME}" \
      --namespace "${NAMESPACE}" \
      --unit Count \
      --value 1 \
      --region "${REGION}"
    echo "✓ Failover metric published. DNS will switch within ~60 seconds (TTL dependent)."
    echo ""
    echo "  Monitor with: ./scripts/failover.sh status --region ${REGION}"
    ;;

  restore)
    echo "🔄 Restoring primary region..."
    aws cloudwatch put-metric-data \
      --metric-name "${METRIC_NAME}" \
      --namespace "${NAMESPACE}" \
      --unit Count \
      --value 0 \
      --region "${REGION}"
    echo "✓ Restore metric published. DNS will switch back within ~60 seconds (TTL dependent)."
    ;;

  status)
    echo "📊 Failover alarm status:"
    aws cloudwatch describe-alarms \
      --alarm-names "${ALARM_NAME}" \
      --region "${REGION}" \
      --query 'MetricAlarms[0].{Name:AlarmName,State:StateValue,Reason:StateReason}' \
      --output table
    echo ""
    echo "Health check status:"
    # Get health check ID from the alarm tags or list all
    HEALTH_CHECK_IDS=$(aws route53 list-health-checks \
      --query "HealthChecks[?HealthCheckConfig.AlarmIdentifier.Name=='${ALARM_NAME}'].Id" \
      --output text 2>/dev/null || echo "")
    if [ -n "${HEALTH_CHECK_IDS}" ]; then
      for hc_id in ${HEALTH_CHECK_IDS}; do
        STATUS=$(aws route53 get-health-check-status \
          --health-check-id "${hc_id}" \
          --query 'HealthCheckObservations[0].StatusReport.Status' \
          --output text 2>/dev/null || echo "Unknown")
        echo "  Health Check ${hc_id}: ${STATUS}"
      done
    else
      echo "  (Could not find associated health check)"
    fi
    ;;

  *)
    echo "Usage: $0 {trigger|restore|status} [--region REGION]"
    echo ""
    echo "Commands:"
    echo "  trigger  — Failover to secondary region"
    echo "  restore  — Return traffic to primary region"
    echo "  status   — Show current alarm and health check state"
    exit 1
    ;;
esac
