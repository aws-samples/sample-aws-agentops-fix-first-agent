"""Send traffic through the AgentCore Gateway for A/B testing.

Each request gets a unique session ID. The A/B test assigns each session
to control or treatment based on the configured traffic weights.

Usage: python send_traffic.py <gateway_url> <region> <prompts_file>
"""
import uuid
import json
import time
import sys

import botocore.session
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
import requests as http_requests

gateway_url = sys.argv[1]
region = sys.argv[2]
prompts_file = sys.argv[3]
target_path = sys.argv[4] if len(sys.argv) > 4 else '/control/invocations'

url = f'{gateway_url}{target_path}'
print(f'Gateway endpoint: {url}')
print(f'Region: {region}')
print(f'Prompts file: {prompts_file}')
print()

with open(prompts_file) as f:
    prompts = [line.strip() for line in f if line.strip()]

session = botocore.session.get_session()
credentials = session.get_credentials().get_frozen_credentials()

for i, prompt in enumerate(prompts):
    sid = f'abtest-{uuid.uuid4()}'
    payload = json.dumps({'prompt': prompt})
    headers = {
        'Content-Type': 'application/json',
        'X-Amzn-Bedrock-AgentCore-Runtime-Session-Id': sid,
    }
    request = AWSRequest(method='POST', url=url, data=payload, headers=headers)
    SigV4Auth(credentials, 'bedrock-agentcore', region).add_auth(request)
    response = http_requests.post(url, data=payload, headers=dict(request.headers))

    print(f'[{i+1}/{len(prompts)}] {prompt}')
    print(f'  Status: {response.status_code}')
    text = response.text[:150] + '...' if len(response.text) > 150 else response.text
    print(f'  Response: {text}')
    print()
    time.sleep(2)

from datetime import datetime, timedelta

print(f'Traffic sent: {len(prompts)} requests through gateway')
print(f'Completed at: {datetime.now().strftime("%H:%M:%S")}')
print(f'Check results after: {(datetime.now() + timedelta(minutes=20)).strftime("%H:%M:%S")} (~20 min for session timeout + scoring)')
