#!/bin/bash
# Send traffic through the AgentCore Gateway for A/B testing.
#
# Uses curl --aws-sigv4 if available (Linux/macOS with curl >= 7.75).
# Falls back to Python with botocore for SigV4 signing (Windows Git Bash).
#
# Usage: ./send_traffic.sh <gateway_url> <region> <prompts_file> [target_path]

set -euo pipefail

GATEWAY_URL="$1"
REGION="$2"
PROMPTS_FILE="$3"
TARGET_PATH="${4:-/control/invocations}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if curl supports --aws-sigv4
if curl --aws-sigv4 2>&1 | grep -q "option --aws-sigv4"; then
    HAS_SIGV4=false
else
    HAS_SIGV4=true
fi

if [ "$HAS_SIGV4" = false ]; then
    echo "curl --aws-sigv4 not available, using Python fallback..."
    python3 "${SCRIPT_DIR}/send_traffic.py" "$GATEWAY_URL" "$REGION" "$PROMPTS_FILE" "$TARGET_PATH" || \
    python "${SCRIPT_DIR}/send_traffic.py" "$GATEWAY_URL" "$REGION" "$PROMPTS_FILE" "$TARGET_PATH"
    exit $?
fi

URL="${GATEWAY_URL}${TARGET_PATH}"
echo "Gateway endpoint: ${URL}"
echo "Region: ${REGION}"
echo "Prompts file: ${PROMPTS_FILE}"
echo ""

COUNT=0
TOTAL=$(grep -c . "$PROMPTS_FILE" 2>/dev/null || wc -l < "$PROMPTS_FILE")

while IFS= read -r prompt; do
    [ -z "$prompt" ] && continue
    COUNT=$((COUNT + 1))
    SID="abtest-$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c 'import uuid;print(uuid.uuid4())')"

    RESPONSE=$(curl -s -w "\n%{http_code}" \
        --aws-sigv4 "aws:amz:${REGION}:bedrock-agentcore" \
        --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
        -H "Content-Type: application/json" \
        -H "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: ${SID}" \
        -d "{\"prompt\": \"${prompt}\"}" \
        "${URL}")

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
