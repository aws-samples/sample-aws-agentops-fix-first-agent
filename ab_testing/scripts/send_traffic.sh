#!/bin/bash
# Send traffic through the AgentCore Gateway for A/B testing.
#
# Uses curl --aws-sigv4 for SigV4-signed requests.
# Resolves credentials from the AWS credential chain (instance roles, SSO, env vars).
#
# Usage: ./send_traffic.sh <gateway_url> <region> <prompts_file> [target_path]

set -euo pipefail

GATEWAY_URL="$1"
REGION="$2"
PROMPTS_FILE="$3"
TARGET_PATH="${4:-/control/invocations}"

URL="${GATEWAY_URL}${TARGET_PATH}"
echo "Gateway endpoint: ${URL}"
echo "Region: ${REGION}"
echo "Prompts file: ${PROMPTS_FILE}"
echo ""

# Resolve credentials from the credential chain (supports instance roles, SSO, env vars)
if [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
    echo "Resolving AWS credentials from credential chain..."
    eval "$(python3 -c "
import botocore.session
s = botocore.session.get_session()
creds = s.get_credentials().get_frozen_credentials()
print(f'export AWS_ACCESS_KEY_ID={creds.access_key}')
print(f'export AWS_SECRET_ACCESS_KEY={creds.secret_key}')
if creds.token:
    print(f'export AWS_SESSION_TOKEN={creds.token}')
")"
    echo "Credentials resolved."
fi

COUNT=0
TOTAL=$(grep -c . "$PROMPTS_FILE" 2>/dev/null || wc -l < "$PROMPTS_FILE")

while IFS= read -r prompt; do
    [ -z "$prompt" ] && continue
    COUNT=$((COUNT + 1))
    SID="abtest-$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c 'import uuid;print(uuid.uuid4())')"

    # Build curl command with session token if present
    CURL_ARGS=(
        -s -w "\n%{http_code}"
        --aws-sigv4 "aws:amz:${REGION}:bedrock-agentcore"
        --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}"
        -H "Content-Type: application/json"
        -H "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: ${SID}"
        -d "{\"prompt\": \"${prompt}\"}"
    )
    if [ -n "${AWS_SESSION_TOKEN:-}" ]; then
        CURL_ARGS+=(-H "x-amz-security-token: ${AWS_SESSION_TOKEN}")
    fi

    RESPONSE=$(curl "${CURL_ARGS[@]}" "${URL}")

    HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    BODY=$(echo "$RESPONSE" | sed '$d')
    BODY_SHORT="${BODY:0:150}"

    echo "[${COUNT}/${TOTAL}] ${prompt}"
    echo "  Status: ${HTTP_CODE}"
    echo "  Response: ${BODY_SHORT}"
    echo ""
    sleep 2
done < "$PROMPTS_FILE"

echo "Traffic sent: ${COUNT} requests through gateway"
echo "Completed at: $(date +%H:%M:%S)"
echo "Check results after: $(date -d '+20 minutes' +%H:%M:%S 2>/dev/null || date -v+20M +%H:%M:%S 2>/dev/null || echo '~20 minutes from now') (~20 min for session timeout + scoring)"
