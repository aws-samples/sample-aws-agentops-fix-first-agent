"""
Lambda proxy handler for multi-region AgentCore Runtime invocation.

This function sits behind API Gateway and forwards requests to the local
region's AgentCore Runtime using the AWS SDK. It handles:
- Bearer token passthrough from the client
- Session ID management
- Streaming response aggregation (API Gateway doesn't support true streaming,
  so we collect the full response and return it as JSON)

Environment variables:
- AGENT_RUNTIME_ARN: ARN of the AgentCore Runtime in this region
- COGNITO_USER_POOL_ID: Cognito User Pool ID for token validation context
- COGNITO_REGION: Region where Cognito is deployed
"""

import json
import os
import logging
import boto3
from botocore.config import Config

logger = logging.getLogger()
logger.setLevel(logging.INFO)

AGENT_RUNTIME_ARN = os.environ['AGENT_RUNTIME_ARN']
COGNITO_USER_POOL_ID = os.environ.get('COGNITO_USER_POOL_ID', '')
COGNITO_REGION = os.environ.get('COGNITO_REGION', '')

# Configure boto3 client with retries
client_config = Config(
    retries={'max_attempts': 3, 'mode': 'adaptive'},
    connect_timeout=10,
    read_timeout=120,
)
agentcore_client = boto3.client('bedrock-agentcore', config=client_config)


def handler(event, context):
    """
    API Gateway Lambda proxy integration handler.

    Expects POST /invoke with:
    - Header: Authorization (Bearer token)
    - Header: X-Session-Id (optional, for session continuity)
    - Header: X-User-Id (optional, for user identification)
    - Body: {"prompt": "..."}
    """
    logger.info(f"Received request: method={event.get('httpMethod')}, path={event.get('path')}")

    # Handle preflight
    if event.get('httpMethod') == 'OPTIONS':
        return _cors_response(200, '')

    # Extract headers (API Gateway lowercases them)
    headers = event.get('headers', {}) or {}
    auth_header = headers.get('authorization') or headers.get('Authorization') or ''
    session_id = (
        headers.get('x-session-id')
        or headers.get('X-Session-Id')
        or context.aws_request_id
    )
    user_id = headers.get('x-user-id') or headers.get('X-User-Id') or 'UNKNOWN'

    # Validate authorization
    if not auth_header.startswith('Bearer '):
        return _cors_response(401, json.dumps({'error': 'Missing or invalid Authorization header'}))

    bearer_token = auth_header[len('Bearer '):]

    # Parse request body
    try:
        body = json.loads(event.get('body', '{}'))
    except (json.JSONDecodeError, TypeError):
        return _cors_response(400, json.dumps({'error': 'Invalid JSON body'}))

    prompt = body.get('prompt', '')
    if not prompt:
        return _cors_response(400, json.dumps({'error': 'Missing "prompt" in request body'}))

    # Invoke AgentCore Runtime
    try:
        payload = json.dumps({'prompt': prompt}).encode('utf-8')

        response = agentcore_client.invoke_agent_runtime(
            agentRuntimeArn=AGENT_RUNTIME_ARN,
            runtimeSessionId=session_id,
            qualifier='DEFAULT',
            payload=payload,
            bearerToken=bearer_token,
            customHeaders={
                'X-Amzn-Bedrock-AgentCore-Runtime-Custom-User-Id': user_id,
            },
        )

        # Process the streaming response
        content_type = response.get('contentType', 'application/json')
        result = _read_response(response, content_type)

        return _cors_response(200, json.dumps({
            'response': result,
            'sessionId': session_id,
            'region': os.environ.get('AWS_REGION', 'unknown'),
        }))

    except agentcore_client.exceptions.ValidationException as e:
        logger.error(f"Validation error: {e}")
        return _cors_response(400, json.dumps({'error': str(e)}))

    except agentcore_client.exceptions.ResourceNotFoundException as e:
        logger.error(f"Runtime not found: {e}")
        return _cors_response(404, json.dumps({'error': 'Agent runtime not found in this region'}))

    except agentcore_client.exceptions.AccessDeniedException as e:
        logger.error(f"Access denied: {e}")
        return _cors_response(403, json.dumps({'error': 'Access denied to agent runtime'}))

    except agentcore_client.exceptions.ThrottlingException as e:
        logger.error(f"Throttled: {e}")
        return _cors_response(429, json.dumps({'error': 'Too many requests, please retry'}))

    except Exception as e:
        logger.error(f"Unexpected error invoking AgentCore Runtime: {e}", exc_info=True)
        return _cors_response(502, json.dumps({
            'error': 'Failed to invoke agent runtime',
            'detail': str(e),
        }))


def _read_response(response, content_type):
    """Read and aggregate the AgentCore Runtime response."""
    if 'text/event-stream' in content_type:
        # SSE streaming response — collect all data lines
        content_parts = []
        for line in response['response'].iter_lines(chunk_size=1024):
            if line:
                decoded = line.decode('utf-8')
                if decoded.startswith('data: '):
                    content_parts.append(decoded[6:])
                else:
                    content_parts.append(decoded)
        return '\n'.join(content_parts)

    elif content_type == 'application/json':
        # Standard JSON response
        chunks = []
        for chunk in response.get('response', []):
            chunks.append(chunk.decode('utf-8'))
        return json.loads(''.join(chunks))

    else:
        # Raw response
        chunks = []
        for chunk in response.get('response', []):
            if isinstance(chunk, bytes):
                chunks.append(chunk.decode('utf-8'))
            else:
                chunks.append(str(chunk))
        return ''.join(chunks)


def _cors_response(status_code, body):
    """Return an API Gateway proxy response with CORS headers."""
    return {
        'statusCode': status_code,
        'headers': {
            'Content-Type': 'application/json',
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Headers': 'Content-Type,Authorization,X-Session-Id,X-User-Id,X-Amzn-Trace-Id',
            'Access-Control-Allow-Methods': 'POST,OPTIONS',
        },
        'body': body,
    }
