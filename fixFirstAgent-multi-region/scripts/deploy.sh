#!/bin/bash
# Deploy the multi-region failover infrastructure for FixFirst Agent.
#
# Three-phase deployment:
#   Phase 0: Deploy prerequisites (Route 53 hosted zone + ACM certificates in both regions)
#   Phase 1: Deploy regional proxy stacks (API Gateway + Lambda) in both regions
#   Phase 2: Deploy routing stack (Route 53 failover records + health checks)
#
# Prerequisites:
#   1. The fixFirstAgent stack must already be deployed in BOTH regions.
#   2. You must own a domain and (after Phase 0) update NS records at your registrar.
#
# Usage:
#   ./scripts/deploy.sh \
#     --domain api.fixfirst.example.com \
#     --hosted-zone-name fixfirst.example.com \
#     --primary-region us-east-1 \
#     --secondary-region us-west-2 \
#     --primary-runtime-arn arn:aws:bedrock-agentcore:us-east-1:123456789012:runtime/abc123 \
#     --secondary-runtime-arn arn:aws:bedrock-agentcore:us-west-2:123456789012:runtime/def456 \
#     --cognito-pool-id us-east-1_XXXXXXXXX
#
# Optional:
#   --existing-hosted-zone-id ZXXXXX   (skip hosted zone creation if you already have one)
#   --phase 0|1|2|all                  (run only a specific phase, default: all)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CDK_DIR="$(cd "${SCRIPT_DIR}/../cdk" && pwd)"

# Parse arguments
PHASE="all"
EXISTING_HZ_ID=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --domain) DOMAIN="$2"; shift 2 ;;
    --hosted-zone-name) HZ_NAME="$2"; shift 2 ;;
    --existing-hosted-zone-id) EXISTING_HZ_ID="$2"; shift 2 ;;
    --primary-region) PRIMARY_REGION="$2"; shift 2 ;;
    --secondary-region) SECONDARY_REGION="$2"; shift 2 ;;
    --primary-runtime-arn) PRIMARY_ARN="$2"; shift 2 ;;
    --secondary-runtime-arn) SECONDARY_ARN="$2"; shift 2 ;;
    --cognito-pool-id) COGNITO_POOL="$2"; shift 2 ;;
    --cognito-region) COGNITO_REGION="$2"; shift 2 ;;
    --phase) PHASE="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Defaults
PRIMARY_REGION="${PRIMARY_REGION:-us-east-1}"
SECONDARY_REGION="${SECONDARY_REGION:-us-west-2}"
COGNITO_REGION="${COGNITO_REGION:-$PRIMARY_REGION}"
APP_NAME="fixFirstAgent"

# Validate required params
for var in DOMAIN HZ_NAME PRIMARY_ARN SECONDARY_ARN COGNITO_POOL; do
  if [ -z "${!var:-}" ]; then
    echo "ERROR: --$(echo $var | tr '_' '-' | tr '[:upper:]' '[:lower:]') is required"
    exit 1
  fi
done

echo "============================================"
echo "  FixFirst Agent — Multi-Region Deployment"
echo "============================================"
echo ""
echo "  Domain:           ${DOMAIN}"
echo "  Hosted Zone:      ${HZ_NAME}"
echo "  Primary Region:   ${PRIMARY_REGION}"
echo "  Secondary Region: ${SECONDARY_REGION}"
echo "  Cognito Region:   ${COGNITO_REGION}"
echo "  Phase:            ${PHASE}"
echo ""

cd "${CDK_DIR}"

# Install dependencies
echo "=== Installing CDK dependencies ==="
npm install

# Base context arguments (always needed)
BASE_CTX=(
  -c "domainName=${DOMAIN}"
  -c "hostedZoneName=${HZ_NAME}"
  -c "primaryRegion=${PRIMARY_REGION}"
  -c "secondaryRegion=${SECONDARY_REGION}"
  -c "primaryAgentRuntimeArn=${PRIMARY_ARN}"
  -c "secondaryAgentRuntimeArn=${SECONDARY_ARN}"
  -c "cognitoUserPoolId=${COGNITO_POOL}"
  -c "cognitoRegion=${COGNITO_REGION}"
)

if [ -n "${EXISTING_HZ_ID}" ]; then
  BASE_CTX+=(-c "existingHostedZoneId=${EXISTING_HZ_ID}")
fi

# ═══════════════════════════════════════════════════════════════════════
# PHASE 0: Prerequisites (Hosted Zone + ACM Certificates)
# ═══════════════════════════════════════════════════════════════════════

if [[ "${PHASE}" == "all" || "${PHASE}" == "0" ]]; then
  echo ""
  echo "=== Phase 0a: Deploy Prerequisites — Primary (${PRIMARY_REGION}) ==="
  npx cdk deploy "${APP_NAME}-Prerequisites-Primary" \
    --require-approval never \
    "${BASE_CTX[@]}"

  echo ""
  echo "=== Phase 0b: Deploy Prerequisites — Secondary (${SECONDARY_REGION}) ==="
  npx cdk deploy "${APP_NAME}-Prerequisites-Secondary" \
    --require-approval never \
    "${BASE_CTX[@]}"

  # If a new hosted zone was created, remind user about NS records
  if [ -z "${EXISTING_HZ_ID}" ]; then
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║  ACTION REQUIRED: Update your domain registrar's NS records!   ║"
    echo "║                                                                ║"
    echo "║  Check the stack output 'NameServers' above and add those      ║"
    echo "║  NS records to your domain registrar for: ${HZ_NAME}"
    echo "║                                                                ║"
    echo "║  ACM certificates will not validate until DNS is resolvable.   ║"
    echo "║  Wait for certificate status to become ISSUED before Phase 1.  ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    if [[ "${PHASE}" == "all" ]]; then
      echo "Waiting 30 seconds for DNS propagation (may need longer)..."
      sleep 30
    fi
  fi
fi

# ═══════════════════════════════════════════════════════════════════════
# PHASE 1: Regional Proxy Stacks (API Gateway + Lambda)
# ═══════════════════════════════════════════════════════════════════════

if [[ "${PHASE}" == "all" || "${PHASE}" == "1" ]]; then
  echo ""
  echo "=== Reading certificate ARNs from SSM ==="

  PRIMARY_CERT_ARN=$(aws ssm get-parameter \
    --name "/${APP_NAME}/multi-region/certificate-arn" \
    --region "${PRIMARY_REGION}" \
    --query 'Parameter.Value' --output text)

  SECONDARY_CERT_ARN=$(aws ssm get-parameter \
    --name "/${APP_NAME}/multi-region/certificate-arn" \
    --region "${SECONDARY_REGION}" \
    --query 'Parameter.Value' --output text)

  echo "  Primary cert:   ${PRIMARY_CERT_ARN}"
  echo "  Secondary cert: ${SECONDARY_CERT_ARN}"

  PHASE1_CTX=(
    "${BASE_CTX[@]}"
    -c "primaryCertificateArn=${PRIMARY_CERT_ARN}"
    -c "secondaryCertificateArn=${SECONDARY_CERT_ARN}"
  )

  echo ""
  echo "=== Phase 1a: Deploy Regional Proxy — Primary (${PRIMARY_REGION}) ==="
  npx cdk deploy "${APP_NAME}-RegionalProxy-Primary" \
    --require-approval never \
    "${PHASE1_CTX[@]}"

  echo ""
  echo "=== Phase 1b: Deploy Regional Proxy — Secondary (${SECONDARY_REGION}) ==="
  npx cdk deploy "${APP_NAME}-RegionalProxy-Secondary" \
    --require-approval never \
    "${PHASE1_CTX[@]}"
fi

# ═══════════════════════════════════════════════════════════════════════
# PHASE 2: Routing Stack (Route 53 Failover)
# ═══════════════════════════════════════════════════════════════════════

if [[ "${PHASE}" == "all" || "${PHASE}" == "2" ]]; then
  echo ""
  echo "=== Reading regional proxy outputs from SSM ==="

  HOSTED_ZONE_ID=$(aws ssm get-parameter \
    --name "/${APP_NAME}/multi-region/hosted-zone-id" \
    --region "${PRIMARY_REGION}" \
    --query 'Parameter.Value' --output text)

  PRIMARY_API_DOMAIN=$(aws ssm get-parameter \
    --name "/${APP_NAME}/multi-region/api-regional-domain-name" \
    --region "${PRIMARY_REGION}" \
    --query 'Parameter.Value' --output text)

  PRIMARY_API_HZ_ID=$(aws ssm get-parameter \
    --name "/${APP_NAME}/multi-region/api-regional-hosted-zone-id" \
    --region "${PRIMARY_REGION}" \
    --query 'Parameter.Value' --output text)

  SECONDARY_API_DOMAIN=$(aws ssm get-parameter \
    --name "/${APP_NAME}/multi-region/api-regional-domain-name" \
    --region "${SECONDARY_REGION}" \
    --query 'Parameter.Value' --output text)

  SECONDARY_API_HZ_ID=$(aws ssm get-parameter \
    --name "/${APP_NAME}/multi-region/api-regional-hosted-zone-id" \
    --region "${SECONDARY_REGION}" \
    --query 'Parameter.Value' --output text)

  echo "  Hosted Zone ID:       ${HOSTED_ZONE_ID}"
  echo "  Primary API Domain:   ${PRIMARY_API_DOMAIN}"
  echo "  Primary API HZ ID:    ${PRIMARY_API_HZ_ID}"
  echo "  Secondary API Domain: ${SECONDARY_API_DOMAIN}"
  echo "  Secondary API HZ ID:  ${SECONDARY_API_HZ_ID}"

  # Read cert ARNs if not already set
  if [ -z "${PRIMARY_CERT_ARN:-}" ]; then
    PRIMARY_CERT_ARN=$(aws ssm get-parameter \
      --name "/${APP_NAME}/multi-region/certificate-arn" \
      --region "${PRIMARY_REGION}" \
      --query 'Parameter.Value' --output text)
    SECONDARY_CERT_ARN=$(aws ssm get-parameter \
      --name "/${APP_NAME}/multi-region/certificate-arn" \
      --region "${SECONDARY_REGION}" \
      --query 'Parameter.Value' --output text)
  fi

  PHASE2_CTX=(
    "${BASE_CTX[@]}"
    -c "primaryCertificateArn=${PRIMARY_CERT_ARN}"
    -c "secondaryCertificateArn=${SECONDARY_CERT_ARN}"
    -c "hostedZoneId=${HOSTED_ZONE_ID}"
    -c "primaryApiDomainName=${PRIMARY_API_DOMAIN}"
    -c "primaryApiHostedZoneId=${PRIMARY_API_HZ_ID}"
    -c "secondaryApiDomainName=${SECONDARY_API_DOMAIN}"
    -c "secondaryApiHostedZoneId=${SECONDARY_API_HZ_ID}"
  )

  echo ""
  echo "=== Phase 2: Deploy Routing Stack (Route 53 failover) ==="
  npx cdk deploy "${APP_NAME}-RoutingStack" \
    --require-approval never \
    "${PHASE2_CTX[@]}"
fi

# ═══════════════════════════════════════════════════════════════════════

echo ""
echo "============================================"
echo "  Multi-Region Deployment Complete!"
echo ""
echo "  Agent endpoint: https://${DOMAIN}/invoke"
echo ""
echo "  To trigger failover:"
echo "    ./scripts/failover.sh trigger --region ${PRIMARY_REGION}"
echo ""
echo "  To return to primary:"
echo "    ./scripts/failover.sh restore --region ${PRIMARY_REGION}"
echo ""
echo "  To check status:"
echo "    ./scripts/failover.sh status --region ${PRIMARY_REGION}"
echo "============================================"
