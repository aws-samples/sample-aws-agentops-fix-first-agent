"""Shadow Traffic Lambda.

Triggered by CloudWatch Logs subscription filter on the PROD endpoint log group.
Extracts user prompts from PROD invocation logs and replays them against PREPROD.
PREPROD responses are automatically logged to PREPROD's own log group by AgentCore,
enabling batch evaluation comparison between PROD and PREPROD.
"""
import base64
import gzip
import json
import os
import re
import time
import uuid
import urllib.request
import urllib.error
import urllib.parse

import boto3

REGION = os.environ["AWS_REGION"]
RUNTIME_ARN = os.environ["RUNTIME_ARN"]
SHADOW_ENDPOINT = os.environ.get("SHADOW_ENDPOINT", "PREPROD")
COGNITO_CLIENT_ID = os.environ["COGNITO_CLIENT_ID"]
COGNITO_USERNAME = os.environ["COGNITO_USERNAME"]
COGNITO_PASSWORD_PARAM = os.environ["COGNITO_PASSWORD_PARAM"]  # SSM SecureString

ssm = boto3.client("ssm", region_name=REGION)
cognito_client = boto3.client("cognito-idp", region_name=REGION)

# Matches the log line from main.py: log.info("User Input: %s", user_input[:200])
PROMPT_PATTERN = re.compile(r"User Input:\s*(.+)")

# Token cache for warm Lambda invocations
_cached_token = None
_token_expiry = 0
TOKEN_TTL = 3000  # Refresh token after 50 minutes (Cognito tokens last 60 min)


def get_cognito_token():
    global _cached_token, _token_expiry
    now = time.time()
    if _cached_token and now < _token_expiry:
        return _cached_token

    password = ssm.get_parameter(
        Name=COGNITO_PASSWORD_PARAM, WithDecryption=True
    )["Parameter"]["Value"]
    resp = cognito_client.initiate_auth(
        ClientId=COGNITO_CLIENT_ID,
        AuthFlow="USER_PASSWORD_AUTH",
        AuthParameters={"USERNAME": COGNITO_USERNAME, "PASSWORD": password},
    )
    _cached_token = resp["AuthenticationResult"]["AccessToken"]
    _token_expiry = now + TOKEN_TTL
    return _cached_token


def invoke_agent(prompt, token):
    encoded_arn = urllib.parse.quote(RUNTIME_ARN, safe="")
    url = (
        f"https://bedrock-agentcore.{REGION}.amazonaws.com"
        f"/runtimes/{encoded_arn}/invocations?qualifier={SHADOW_ENDPOINT}"
    )
    session_id = f"shadow-{uuid.uuid4()}"
    req = urllib.request.Request(
        url,
        data=json.dumps({"prompt": prompt}).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
            "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id": session_id,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.read().decode("utf-8", errors="replace")[:200]
    except Exception as e:
        return f"ERROR: {str(e)[:200]}"


def handler(event, context):
    # Decode CloudWatch Logs subscription filter payload
    compressed = base64.b64decode(event["awslogs"]["data"])
    log_data = json.loads(gzip.decompress(compressed))
    log_events = log_data.get("logEvents", [])

    prompts = []
    for log_event in log_events:
        match = PROMPT_PATTERN.search(log_event.get("message", ""))
        if match:
            prompt = match.group(1).strip()
            if len(prompt) > 3:
                prompts.append(prompt)

    if not prompts:
        return {"replayed": 0}

    token = get_cognito_token()
    results = []
    for prompt in prompts:
        result = invoke_agent(prompt, token)
        results.append(result)

    return {"replayed": len(prompts), "errors": sum(1 for r in results if r.startswith("ERROR"))}
