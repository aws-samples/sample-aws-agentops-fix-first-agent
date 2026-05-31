"""Create AgentCore Gateway, HTTP targets, and A/B test.

This script is executed locally during CDK deployment via ILocalBundling.
It reads configuration from environment variables and creates the A/B test infrastructure.

If resources already exist, they are deleted and recreated to ensure a consistent state.
All operations fail gracefully — errors are logged but do not halt execution.
"""
import boto3
import json
import os
import time
import uuid

REGION = os.environ.get('AWS_REGION', os.environ.get('CDK_DEFAULT_REGION', 'us-east-1'))
APP_NAME = os.environ.get('APP_NAME', 'fixFirstAgent')
CONTROL_RUNTIME_ARN = os.environ['CONTROL_RUNTIME_ARN']
REFINED_RUNTIME_ARN = os.environ['REFINED_RUNTIME_ARN']
CONTROL_EVAL_ARN = os.environ['CONTROL_EVAL_ARN']
TREATMENT_EVAL_ARN = os.environ['TREATMENT_EVAL_ARN']
OUTPUT_DIR = os.environ.get('OUTPUT_DIR', '.')

cp_client = boto3.client('bedrock-agentcore-control', region_name=REGION)
dp_client = boto3.client('bedrock-agentcore', region_name=REGION)
ssm_client = boto3.client('ssm', region_name=REGION)
iam_client = boto3.client('iam', region_name=REGION)

GATEWAY_NAME = f'{APP_NAME}-ABTest-Gateway'
ROLE_NAME = f'{APP_NAME}-ABGatewayRole'


def wait_for_gateway(gateway_id, timeout=120):
    for _ in range(timeout // 5):
        status = cp_client.get_gateway(gatewayIdentifier=gateway_id)['status']
        if status == 'READY':
            return
        time.sleep(5)
    raise TimeoutError(f'Gateway {gateway_id} not READY after {timeout}s')


def cleanup_existing():
    """Remove any existing gateway, targets, and A/B test. Fail gracefully."""
    print('--- Cleaning up existing resources ---')

    existing_gateways = cp_client.list_gateways().get('items', [])
    existing = [g for g in existing_gateways if g['name'] == GATEWAY_NAME]

    if not existing:
        print('No existing gateway found, skipping cleanup')
        return

    gateway_id = existing[0]['gatewayId']
    gateway_arn = existing[0].get('gatewayArn', '')

    # Stop and delete any running A/B tests on this gateway
    try:
        existing_tests = dp_client.list_ab_tests().get('abTests', [])
        for test in existing_tests:
            if test.get('gatewayArn') == gateway_arn or test.get('gatewayArn', '').endswith(gateway_id):
                try:
                    dp_client.update_ab_test(
                        abTestId=test['abTestId'],
                        executionStatus='STOPPED',
                        clientToken=str(uuid.uuid4()),
                    )
                    print(f'  A/B test stopped: {test["abTestId"]}')
                    time.sleep(10)
                except Exception as e:
                    print(f'  Stop A/B test: {e}')
                try:
                    dp_client.delete_ab_test(abTestId=test['abTestId'])
                    print(f'  A/B test deleted: {test["abTestId"]}')
                except Exception as e:
                    print(f'  Delete A/B test: {e}')
    except Exception as e:
        print(f'  List/delete A/B tests: {e}')

    # Delete targets
    try:
        targets = cp_client.list_gateway_targets(gatewayIdentifier=gateway_id).get('items', [])
        for t in targets:
            try:
                cp_client.delete_gateway_target(gatewayIdentifier=gateway_id, targetName=t['name'])
                print(f'  Target deleted: {t["name"]}')
            except Exception as e:
                print(f'  Delete target {t["name"]}: {e}')
        if targets:
            time.sleep(10)
    except Exception as e:
        print(f'  List/delete targets: {e}')

    # Delete gateway
    try:
        cp_client.delete_gateway(gatewayIdentifier=gateway_id)
        print(f'  Gateway deleted: {gateway_id}')
        time.sleep(10)
    except Exception as e:
        print(f'  Delete gateway: {e}')

    print('--- Cleanup complete ---\n')


def ensure_role():
    """Create or reuse the IAM role for the gateway."""
    account_id = boto3.client('sts', region_name=REGION).get_caller_identity()['Account']

    try:
        role_resp = iam_client.get_role(RoleName=ROLE_NAME)
        role_arn = role_resp['Role']['Arn']
        print(f'IAM role exists: {role_arn}')
        return role_arn
    except iam_client.exceptions.NoSuchEntityException:
        pass

    role_resp = iam_client.create_role(
        RoleName=ROLE_NAME,
        AssumeRolePolicyDocument=json.dumps({
            'Version': '2012-10-17',
            'Statement': [{
                'Effect': 'Allow',
                'Principal': {'Service': 'bedrock-agentcore.amazonaws.com'},
                'Action': 'sts:AssumeRole',
            }]
        }),
    )
    role_arn = role_resp['Role']['Arn']
    iam_client.put_role_policy(
        RoleName=ROLE_NAME,
        PolicyName='GatewayPolicy',
        PolicyDocument=json.dumps({
            'Version': '2012-10-17',
            'Statement': [
                {
                    'Effect': 'Allow',
                    'Action': 'bedrock-agentcore:*',
                    'Resource': f'arn:aws:bedrock-agentcore:{REGION}:{account_id}:*',
                },
                {
                    'Effect': 'Allow',
                    'Action': ['logs:StartQuery', 'logs:GetQueryResults', 'logs:DescribeLogGroups',
                               'logs:DescribeLogStreams', 'logs:GetLogEvents', 'logs:FilterLogEvents'],
                    'Resource': '*',
                },
            ]
        }),
    )
    print(f'IAM role created: {role_arn}')
    time.sleep(10)  # Wait for IAM propagation
    return role_arn


def main():
    print(f'Region: {REGION}')
    print(f'Control Runtime: {CONTROL_RUNTIME_ARN}')
    print(f'Refined Runtime: {REFINED_RUNTIME_ARN}')
    print(f'Control Eval: {CONTROL_EVAL_ARN}')
    print(f'Treatment Eval: {TREATMENT_EVAL_ARN}\n')

    # Clean up any existing resources first
    cleanup_existing()

    # Ensure IAM role exists
    role_arn = ensure_role()

    # Create gateway
    gw = cp_client.create_gateway(
        name=GATEWAY_NAME,
        roleArn=role_arn,
        authorizerType='AWS_IAM',
    )
    gateway_id = gw['gatewayId']
    gateway_arn = gw['gatewayArn']
    gateway_url = gw['gatewayUrl']
    print(f'Gateway created: {gateway_id}')
    wait_for_gateway(gateway_id)
    print('Gateway is READY')

    # Create targets
    cp_client.create_gateway_target(
        gatewayIdentifier=gateway_id,
        name='control',
        targetConfiguration={'http': {'agentcoreRuntime': {'arn': CONTROL_RUNTIME_ARN, 'qualifier': 'DEFAULT'}}},
        credentialProviderConfigurations=[{'credentialProviderType': 'GATEWAY_IAM_ROLE'}],
        clientToken=str(uuid.uuid4()),
    )
    print('Target created: control')

    cp_client.create_gateway_target(
        gatewayIdentifier=gateway_id,
        name='treatment',
        targetConfiguration={'http': {'agentcoreRuntime': {'arn': REFINED_RUNTIME_ARN, 'qualifier': 'DEFAULT'}}},
        credentialProviderConfigurations=[{'credentialProviderType': 'GATEWAY_IAM_ROLE'}],
        clientToken=str(uuid.uuid4()),
    )
    print('Target created: treatment')

    # Wait for targets to become ready
    time.sleep(10)

    # Create A/B test
    ab_test = dp_client.create_ab_test(
        name=f'fixfirstagent_abtest_{uuid.uuid4().hex[:8]}',
        gatewayArn=gateway_arn,
        variants=[
            {'name': 'C', 'weight': 50, 'variantConfiguration': {'target': {'name': 'control'}}},
            {'name': 'T1', 'weight': 50, 'variantConfiguration': {'target': {'name': 'treatment'}}},
        ],
        gatewayFilter={'targetPaths': ['/control/*']},
        evaluationConfig={
            'perVariantOnlineEvaluationConfig': [
                {'name': 'C', 'onlineEvaluationConfigArn': CONTROL_EVAL_ARN},
                {'name': 'T1', 'onlineEvaluationConfigArn': TREATMENT_EVAL_ARN},
            ]
        },
        roleArn=role_arn,
        enableOnCreate=True,
        clientToken=str(uuid.uuid4()),
    )
    ab_test_id = ab_test['abTestId']
    print(f'A/B test created: {ab_test_id}')

    # Store results in SSM
    params = {
        f'/{APP_NAME}/ab-gateway-id': gateway_id,
        f'/{APP_NAME}/ab-gateway-arn': gateway_arn,
        f'/{APP_NAME}/ab-gateway-url': gateway_url,
        f'/{APP_NAME}/ab-test-id': ab_test_id,
    }
    for name, value in params.items():
        ssm_client.put_parameter(Name=name, Value=value, Type='String', Overwrite=True)
        print(f'SSM: {name} = {value}')

    # Write output file for CDK asset requirement
    with open(os.path.join(OUTPUT_DIR, 'result.json'), 'w') as f:
        json.dump({'gatewayId': gateway_id, 'gatewayUrl': gateway_url, 'abTestId': ab_test_id}, f, indent=2)

    print('\nDone! Gateway, targets, and A/B test are ready.')


if __name__ == '__main__':
    main()
