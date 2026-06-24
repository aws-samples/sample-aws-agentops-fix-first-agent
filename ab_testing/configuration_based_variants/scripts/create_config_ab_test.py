"""Create configuration bundles, gateway, and A/B test for config-based variant testing.

This script runs AFTER the CDK stack deploys the runtime, eval config, and IAM roles.
It reads ARNs from SSM and creates:
1. Two configuration bundles (control + treatment system prompts)
2. An AgentCore Gateway with one HTTP target
3. An A/B test with configurationBundle variants (50/50 split)

All resource IDs are stored in SSM for use by subsequent steps.

Usage:
    python create_config_ab_test.py
    python create_config_ab_test.py --control-prompt "prompt1" --treatment-prompt "prompt2"
    python create_config_ab_test.py --config prompts.json
"""
import argparse
import boto3
import json
import os
import time
import uuid

REGION = os.environ.get('AWS_REGION', os.environ.get('CDK_DEFAULT_REGION', 'us-east-1'))
APP_NAME = os.environ.get('APP_NAME', 'fixFirstAgent')

cp_client = boto3.client('bedrock-agentcore-control', region_name=REGION)
dp_client = boto3.client('bedrock-agentcore', region_name=REGION)
ssm_client = boto3.client('ssm', region_name=REGION)

DEFAULT_CONTROL_PROMPT = (
    "You are FixFirst, a friendly support agent for appliance troubleshooting. "
    "Keep responses short and conversational. Ask one question at a time."
)
DEFAULT_TREATMENT_PROMPT = (
    "You are FixFirst Pro, an expert appliance diagnostics agent. "
    "Use structured methodology: IDENTIFY the appliance and symptom, "
    "DIAGNOSE the likely cause, RESOLVE with step-by-step instructions. "
    "Keep responses to 2-3 sentences max."
)


def get_param(name):
    return ssm_client.get_parameter(Name=f'/{APP_NAME}/{name}')['Parameter']['Value']


def delete_bundle_if_exists(bundle_name):
    """Delete a config bundle by name if it exists. Wait for deletion to complete."""
    try:
        bundles = cp_client.list_configuration_bundles().get('bundles', [])
        match = [b for b in bundles if b['bundleName'] == bundle_name]
        if match:
            cp_client.delete_configuration_bundle(bundleId=match[0]['bundleId'])
            print(f'  Deleted existing: {bundle_name}')
            time.sleep(5)
    except Exception as e:
        print(f'  Cleanup {bundle_name}: {e}')


def create_bundle(bundle_name, runtime_arn, system_prompt):
    """Delete existing bundle and create fresh with the given prompt."""
    delete_bundle_if_exists(bundle_name)
    result = cp_client.create_configuration_bundle(
        bundleName=bundle_name,
        components={
            runtime_arn: {
                'configuration': {'system_prompt': system_prompt}
            }
        },
        clientToken=str(uuid.uuid4()),
    )
    bundle_arn = result['bundleArn']
    bundle_version = result['versionId']
    # Print stored config for verification
    detail = cp_client.get_configuration_bundle(bundleId=result['bundleId'])
    print(f'  {bundle_name}:')
    print(f'    ARN: {bundle_arn}')
    print(f'    Version: {bundle_version}')
    print(f'    Prompt: "{system_prompt[:80]}..."')
    return bundle_arn, bundle_version


def main():
    parser = argparse.ArgumentParser(description='Create config-bundle A/B test')
    parser.add_argument('--control-prompt', default=DEFAULT_CONTROL_PROMPT, help='System prompt for control variant')
    parser.add_argument('--treatment-prompt', default=DEFAULT_TREATMENT_PROMPT, help='System prompt for treatment variant')
    parser.add_argument('--config', help='JSON file with {"control_prompt": "...", "treatment_prompt": "..."}')
    args = parser.parse_args()

    # Load prompts from config file if provided
    control_prompt = args.control_prompt
    treatment_prompt = args.treatment_prompt
    if args.config:
        with open(args.config) as f:
            config = json.load(f)
        control_prompt = config.get('control_prompt', control_prompt)
        treatment_prompt = config.get('treatment_prompt', treatment_prompt)

    # Read from SSM (set by CDK stack)
    runtime_arn = get_param('config-runtime-arn')
    eval_arn = get_param('config-eval-arn')
    role_arn = get_param('config-gateway-role-arn')

    print(f'Region: {REGION}')
    print(f'Runtime: {runtime_arn}')
    print(f'Eval: {eval_arn}')
    print(f'Role: {role_arn}')
    print()

    # Create config bundles
    print('Creating configuration bundles...')
    control_arn, control_ver = create_bundle(
        f'{APP_NAME}_config_control', runtime_arn, control_prompt
    )
    treatment_arn, treatment_ver = create_bundle(
        f'{APP_NAME}_config_treatment', runtime_arn, treatment_prompt
    )

    # Create gateway
    print('\nCreating gateway...')
    gateway_name = f'{APP_NAME}-ConfigABTest-Gateway'

    # Delete existing gateway if present
    try:
        gateways = cp_client.list_gateways().get('items', [])
        existing = [g for g in gateways if g['name'] == gateway_name]
        if existing:
            gw_id = existing[0]['gatewayId']
            # Delete targets first
            targets = cp_client.list_gateway_targets(gatewayIdentifier=gw_id).get('items', [])
            for t in targets:
                cp_client.delete_gateway_target(gatewayIdentifier=gw_id, targetId=t['targetId'])
            if targets:
                time.sleep(10)
            cp_client.delete_gateway(gatewayIdentifier=gw_id)
            print(f'  Deleted existing gateway: {gw_id}')
            time.sleep(10)
    except Exception as e:
        print(f'  Gateway cleanup: {e}')

    gw = cp_client.create_gateway(
        name=gateway_name,
        roleArn=role_arn,
        authorizerType='AWS_IAM',
    )
    gateway_id = gw['gatewayId']
    gateway_arn = gw['gatewayArn']
    gateway_url = gw['gatewayUrl']
    print(f'  Gateway: {gateway_id}')

    # Wait for READY
    for _ in range(30):
        status = cp_client.get_gateway(gatewayIdentifier=gateway_id)['status']
        if status == 'READY':
            break
        time.sleep(5)
    print('  Gateway is READY')

    # Create single target
    print('\nCreating target...')
    cp_client.create_gateway_target(
        gatewayIdentifier=gateway_id,
        name='fixfirst',
        targetConfiguration={'http': {'agentcoreRuntime': {'arn': runtime_arn, 'qualifier': 'DEFAULT'}}},
        credentialProviderConfigurations=[{'credentialProviderType': 'GATEWAY_IAM_ROLE'}],
        clientToken=str(uuid.uuid4()),
    )
    print('  Target: fixfirst')
    time.sleep(10)

    # Create A/B test with config bundle variants
    print('\nCreating A/B test...')
    ab_test = dp_client.create_ab_test(
        name=f'fixfirstagent_config_abtest_{uuid.uuid4().hex[:8]}',
        gatewayArn=gateway_arn,
        variants=[
            {
                'name': 'C',
                'weight': 50,
                'variantConfiguration': {
                    'configurationBundle': {
                        'bundleArn': control_arn,
                        'bundleVersion': control_ver,
                    }
                }
            },
            {
                'name': 'T1',
                'weight': 50,
                'variantConfiguration': {
                    'configurationBundle': {
                        'bundleArn': treatment_arn,
                        'bundleVersion': treatment_ver,
                    }
                }
            },
        ],
        gatewayFilter={'targetPaths': ['/fixfirst/*']},
        evaluationConfig={
            'onlineEvaluationConfigArn': eval_arn,
        },
        roleArn=role_arn,
        enableOnCreate=True,
        clientToken=str(uuid.uuid4()),
    )
    ab_test_id = ab_test['abTestId']
    print(f'  A/B test: {ab_test_id}')

    # Store in SSM
    params = {
        f'/{APP_NAME}/config-ab-gateway-id': gateway_id,
        f'/{APP_NAME}/config-ab-gateway-url': gateway_url,
        f'/{APP_NAME}/config-ab-test-id': ab_test_id,
        f'/{APP_NAME}/config-ab-control-bundle-arn': control_arn,
        f'/{APP_NAME}/config-ab-treatment-bundle-arn': treatment_arn,
    }
    for name, value in params.items():
        ssm_client.put_parameter(Name=name, Value=str(value), Type='String', Overwrite=True)

    print(f'\n{"=" * 60}')
    print(f'Gateway URL: {gateway_url}')
    print(f'A/B Test ID: {ab_test_id}')
    print(f'Traffic endpoint: {gateway_url}/fixfirst/invocations')
    print(f'{"=" * 60}')


if __name__ == '__main__':
    main()
