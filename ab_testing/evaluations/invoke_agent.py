#!/usr/bin/env python3
"""Send prompts to fixFirstAgent.

Usage:
    python invoke_agent.py                    # 15 prompts from prompts.txt
    python invoke_agent.py --count 5          # first 5 only
    python invoke_agent.py --region us-east-1

Requires env vars: COGNITO_USERNAME, COGNITO_PASSWORD
"""
import argparse
import boto3
import json
import os
import sys
import uuid
import urllib.request
import urllib.error
import urllib.parse
from pathlib import Path

DEFAULT_PROMPTS_FILE = Path(__file__).parent.parent / "prompts.txt"


def get_ssm_params(region):
    ssm = boto3.client("ssm", region_name=region)
    params = {}
    for name in ["agentcore-runtime-arn", "cognito-client-id"]:
        params[name] = ssm.get_parameter(Name=f"/fixFirstAgent/{name}")["Parameter"]["Value"]
    return params


def get_cognito_token(client_id, username, password, region):
    client = boto3.client("cognito-idp", region_name=region)
    resp = client.initiate_auth(
        ClientId=client_id,
        AuthFlow="USER_PASSWORD_AUTH",
        AuthParameters={"USERNAME": username, "PASSWORD": password},
    )
    return resp["AuthenticationResult"]["AccessToken"]


def invoke(runtime_arn, session_id, prompt, token, region):
    encoded_arn = urllib.parse.quote(runtime_arn, safe="")
    url = f"https://bedrock-agentcore.{region}.amazonaws.com/runtimes/{encoded_arn}/invocations?qualifier=DEFAULT"
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
        with urllib.request.urlopen(req) as resp:
            body = resp.read()
            try:
                return json.loads(body)
            except json.JSONDecodeError:
                return body.decode("utf-8", errors="replace")[:200]
    except urllib.error.HTTPError as e:
        return f"ERROR {e.code}: {e.read().decode('utf-8', errors='replace')[:200]}"


def main():
    parser = argparse.ArgumentParser(description="Send prompts to fixFirstAgent")
    parser.add_argument("--region", default=None)
    parser.add_argument("--count", type=int, default=15)
    parser.add_argument("--prompts-file", default=str(DEFAULT_PROMPTS_FILE))
    args = parser.parse_args()

    region = args.region or boto3.Session().region_name or "us-east-1"
    username = os.environ.get("COGNITO_USERNAME")
    password = os.environ.get("COGNITO_PASSWORD")
    if not username or not password:
        print("ERROR: Set COGNITO_USERNAME and COGNITO_PASSWORD env vars.")
        sys.exit(1)

    prompts = [l.strip() for l in Path(args.prompts_file).read_text().splitlines() if l.strip()]
    prompts = prompts[: args.count]

    params = get_ssm_params(region)
    runtime_arn = params["agentcore-runtime-arn"]
    token = get_cognito_token(params["cognito-client-id"], username, password, region)

    print(f"Runtime: {runtime_arn.split('/')[-1]}  |  Prompts: {len(prompts)}")
    print()

    for i, prompt in enumerate(prompts):
        sid = f"eval-{uuid.uuid4()}"
        print(f"[{i+1}/{len(prompts)}] {prompt[:70]}")
        resp = invoke(runtime_arn, sid, prompt, token, region)
        snippet = json.dumps(resp, default=str)[:120] if isinstance(resp, dict) else str(resp)[:120]
        print(f"  -> {snippet}")
        print()

    print(f"Done. Sent {len(prompts)} requests.")


if __name__ == "__main__":
    main()
