#!/usr/bin/env bash
# End-to-end test for the multi-region proxy backend.
#
# Tests the full path: API Gateway → Lambda Proxy → AgentCore Runtime
# in each deployed region.
#
# Usage:
#   ./scripts/test-proxy.sh --username <cognito-user> --password <cognito-pass>
#
# Optional:
#   --prompt "Your test prompt"       (default: "Hello, what can you help me with?")
#   --health-only                     (skip invoke, just test health endpoints)

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────

# API Gateway endpoints (from CDK deploy outputs)
ENDPOINT_US_WEST_2="https://neo782y142.execute-api.us-west-2.amazonaws.com/v1"
ENDPOINT_US_EAST_1="https://ug0v0mgfsa.execute-api.us-east-1.amazonaws.com/v1"

# ─── Parse Arguments ──────────────────────────────────────────────────

USERNAME=""
PASSWORD=""
PROMPT="Hello, what can you help me with?"
HEALTH_ONLY=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --username) USERNAME="$2"; shift 2 ;;
    --password) PASSWORD="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --health-only) HEALTH_ONLY=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ "${HEALTH_ONLY}" == false && ( -z "${USERNAME}" || -z "${PASSWORD}" ) ]]; then
  echo "ERROR: --username and --password are required for invoke tests."
  echo "       Use --health-only to skip invoke and just test health endpoints."
  echo ""
  echo "Usage: $0 --username <user> --password <pass> [--prompt \"...\"]"
  exit 1
fi

# ─── Helper Functions ─────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}✓ PASS${NC}: $1"; }
fail() { echo -e "  ${RED}✗ FAIL${NC}: $1"; }
info() { echo -e "  ${YELLOW}ℹ${NC} $1"; }

TOTAL_TESTS=0
PASSED_TESTS=0

# Authenticate with Cognito and return an access token
get_token() {
  local region="$1"
  local client_id="$2"

  local cognito_endpoint="https://cognito-idp.${region}.amazonaws.com/"

  local response
  response=$(curl -s -X POST "${cognito_endpoint}" \
    -H "Content-Type: application/x-amz-json-1.1" \
    -H "X-Amz-Target: AWSCognitoIdentityProviderService.InitiateAuth" \
    -d "{
      \"AuthFlow\": \"USER_PASSWORD_AUTH\",
      \"ClientId\": \"${client_id}\",
      \"AuthParameters\": {
        \"USERNAME\": \"${USERNAME}\",
        \"PASSWORD\": \"${PASSWORD}\"
      }
    }" 2>&1)

  if echo "${response}" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if 'AuthenticationResult' in d else 1)" 2>/dev/null; then
    echo "${response}" | python3 -c "import sys,json; print(json.load(sys.stdin)['AuthenticationResult']['AccessToken'])"
  else
    local error_msg
    error_msg=$(echo "${response}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('message', d.get('__type', 'Unknown error')))" 2>/dev/null || echo "Failed to parse response")
    echo "AUTH_ERROR: ${error_msg}"
  fi
}

# Test a single region
test_region() {
  local region="$1"
  local base_url="$2"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Region: ${region}"
  echo "  Endpoint: ${base_url}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # ─── Test 1: Health Check ─────────────────────────────────────────

  echo ""
  echo "  Test 1: GET /health"
  TOTAL_TESTS=$((TOTAL_TESTS + 1))

  local health_response http_code body
  health_response=$(curl -s -w "\n%{http_code}" "${base_url}/health" 2>&1)
  http_code=$(echo "${health_response}" | tail -1)
  body=$(echo "${health_response}" | sed '$d')

  if [ "${http_code}" == "200" ]; then
    local response_region
    response_region=$(echo "${body}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('region',''))" 2>/dev/null || echo "")
    if [ "${response_region}" == "${region}" ]; then
      pass "Health check returned 200, region=${response_region}"
      PASSED_TESTS=$((PASSED_TESTS + 1))
    else
      fail "Health check returned 200 but unexpected region: '${response_region}'"
    fi
  else
    fail "Health check returned HTTP ${http_code}"
    info "Response: ${body}"
  fi

  if [[ "${HEALTH_ONLY}" == true ]]; then
    return
  fi

  # ─── Test 2: Invoke without auth (should get 401) ─────────────────

  echo ""
  echo "  Test 2: POST /invoke without auth (expect 401)"
  TOTAL_TESTS=$((TOTAL_TESTS + 1))

  local noauth_response
  noauth_response=$(curl -s -w "\n%{http_code}" -X POST "${base_url}/invoke" \
    -H "Content-Type: application/json" \
    -d '{"prompt":"test"}' 2>&1)
  http_code=$(echo "${noauth_response}" | tail -1)

  if [ "${http_code}" == "401" ]; then
    pass "Correctly rejected unauthenticated request (401)"
    PASSED_TESTS=$((PASSED_TESTS + 1))
  else
    fail "Expected 401, got HTTP ${http_code}"
    body=$(echo "${noauth_response}" | sed '$d')
    info "Response: ${body:0:200}"
  fi

  # ─── Test 3: Invoke with auth (full end-to-end) ───────────────────

  echo ""
  echo "  Test 3: POST /invoke with auth (full e2e: APIGW → Lambda → AgentCore)"
  TOTAL_TESTS=$((TOTAL_TESTS + 1))

  # Get Cognito client ID from SSM
  local client_id
  client_id=$(aws ssm get-parameter \
    --name "/fixFirstAgent/cognito-client-id" \
    --region "${region}" \
    --query 'Parameter.Value' --output text 2>/dev/null || echo "")

  if [ -z "${client_id}" ]; then
    fail "No Cognito client ID found in ${region} SSM — cannot authenticate"
    return
  fi

  info "Authenticating with Cognito (client: ${client_id:0:10}...)..."
  local token
  token=$(get_token "${region}" "${client_id}")

  if [[ "${token}" == AUTH_ERROR* ]]; then
    fail "Authentication failed: ${token#AUTH_ERROR: }"
    info "Make sure the user exists in the ${region} Cognito pool."
    return
  fi

  info "Got token: ${token:0:20}..."
  info "Invoking agent with prompt: \"${PROMPT}\""

  local invoke_start invoke_end invoke_duration invoke_response
  invoke_start=$(date +%s)
  invoke_response=$(curl -s -w "\n%{http_code}" -X POST "${base_url}/invoke" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${token}" \
    -H "X-Session-Id: test-session-$(date +%s)" \
    -H "X-User-Id: test-user" \
    -d "{\"prompt\": \"${PROMPT}\"}" \
    --max-time 120 2>&1)
  invoke_end=$(date +%s)
  invoke_duration=$((invoke_end - invoke_start))

  http_code=$(echo "${invoke_response}" | tail -1)
  body=$(echo "${invoke_response}" | sed '$d')

  if [ "${http_code}" == "200" ]; then
    local response_region response_text
    response_region=$(echo "${body}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('region',''))" 2>/dev/null || echo "")
    response_text=$(echo "${body}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
resp = d.get('response', '')
if isinstance(resp, str):
    print(resp[:200])
else:
    print(json.dumps(resp)[:200])
" 2>/dev/null || echo "(could not parse)")

    pass "Agent invoked successfully (${invoke_duration}s, region=${response_region})"
    info "Response preview: ${response_text}"
    PASSED_TESTS=$((PASSED_TESTS + 1))
  else
    fail "Invoke returned HTTP ${http_code} (${invoke_duration}s)"
    local error_msg
    error_msg=$(echo "${body}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error','') or d.get('message',''))" 2>/dev/null || echo "${body:0:200}")
    info "Error: ${error_msg}"
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────

echo "============================================"
echo "  FixFirst Agent — Multi-Region Proxy Test"
echo "============================================"

test_region "us-west-2" "${ENDPOINT_US_WEST_2}"
test_region "us-east-1" "${ENDPOINT_US_EAST_1}"

# ─── Summary ──────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Results: ${PASSED_TESTS}/${TOTAL_TESTS} tests passed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "${PASSED_TESTS}" -eq "${TOTAL_TESTS}" ]; then
  echo -e "  ${GREEN}All tests passed!${NC}"
  exit 0
else
  echo -e "  ${RED}Some tests failed.${NC}"
  exit 1
fi
