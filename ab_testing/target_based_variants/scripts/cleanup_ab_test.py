"""Cleanup AgentCore Gateway, targets, A/B test, and IAM role.

This script is called from the notebook before `cdk destroy` to remove
resources that were created by create_ab_test.py via boto3 (not managed by CloudFormation).
"""
import boto3
import json
import os
import time
import uuid

REGION = os.environ.get('AWS_REGION', os.environ.get('CDK_DEFAULT_REGION', 'us-east-1'))
APP_NAME = os.environ.get('APP_NAME', 'fixFirstAgent')

ssm_client = boto3.client('ssm', region_name=REGION)


def get_param(name):
    """Read SSM parameter, return None if not found."""
    try:
        return ssm_client.get_parameter(Name=f'/{APP_NAME}/{name}')['Parameter']['Value']
    except ssm_client.exceptions.ParameterNotFound:
        return None


def delete_param(name):
    """Delete SSM parameter, ignore if not found."""
    try:
        ssm_client.delete_parameter(Name=f'/{APP_NAME}/{name}')
    except ssm_client.exceptions.ParameterNotFound:
        pass


def main():
    print(f'Region: {REGION}, App: {APP_NAME}')

    ab_test_id = get_param('ab-test-id')
    gateway_id = get_param('ab-gateway-id')

    # Fallback: find gateway by name if SSM param is missing
    if not gateway_id:
        try:
            cp_client = boto3.client('bedrock-agentcore-control', region_name=REGION)
            gateways = cp_client.list_gateways().get('items', [])
            match = [g for g in gateways if g['name'] == f'{APP_NAME}-ABTest-Gateway']
            if match:
                gateway_id = match[0]['gatewayId']
                print(f'Found gateway by name: {gateway_id}')
        except Exception as e:
            print(f'Gateway lookup: {e}')

    dp_client = boto3.client('bedrock-agentcore', region_name=REGION)
    cp_client = boto3.client('bedrock-agentcore-control', region_name=REGION)

    # 1. Stop and delete A/B test
    if not ab_test_id and gateway_id:
        # Fallback: find AB test by gateway
        try:
            gw_detail = cp_client.get_gateway(gatewayIdentifier=gateway_id)
            gateway_arn = gw_detail.get('gatewayArn', '')
            tests = dp_client.list_ab_tests().get('abTests', [])
            match = [t for t in tests if t.get('gatewayArn') == gateway_arn]
            if match:
                ab_test_id = match[0]['abTestId']
                print(f'Found A/B test by gateway: {ab_test_id}')
        except Exception as e:
            print(f'A/B test lookup: {e}')

    if ab_test_id:
        try:
            dp_client.update_ab_test(
                abTestId=ab_test_id,
                executionStatus='STOPPED',
                clientToken=str(uuid.uuid4()),
            )
            print(f'A/B test stopped: {ab_test_id}')
            time.sleep(15)
        except Exception as e:
            print(f'Stop A/B test: {e}')

        try:
            dp_client.delete_ab_test(abTestId=ab_test_id)
            print(f'A/B test deleted: {ab_test_id}')
        except Exception as e:
            print(f'Delete A/B test: {e}')
    else:
        print('No A/B test found in SSM')

    # 2. Delete gateway targets then gateway
    if gateway_id:
        try:
            targets = cp_client.list_gateway_targets(gatewayIdentifier=gateway_id).get('items', [])
            for t in targets:
                try:
                    cp_client.delete_gateway_target(gatewayIdentifier=gateway_id, targetId=t['targetId'])
                    print(f'Target deleted: {t["name"]} ({t["targetId"]})')
                except Exception as e:
                    print(f'Delete target {t.get("name", "?")}: {e}')
            if targets:
                time.sleep(10)
        except Exception as e:
            print(f'List/delete targets: {e}')

        try:
            cp_client.delete_gateway(gatewayIdentifier=gateway_id)
            print(f'Gateway deleted: {gateway_id}')
        except Exception as e:
            print(f'Delete gateway: {e}')
    else:
        print('No gateway found in SSM')

    # 3. Delete IAM role
    iam_client = boto3.client('iam', region_name=REGION)
    role_name = f'{APP_NAME}-ABGatewayRole'
    try:
        iam_client.delete_role_policy(RoleName=role_name, PolicyName='GatewayPolicy')
        iam_client.delete_role(RoleName=role_name)
        print(f'IAM role deleted: {role_name}')
    except Exception as e:
        print(f'Delete IAM role: {e}')

    # 4. Clean up SSM parameters
    for param in ['ab-gateway-id', 'ab-gateway-arn', 'ab-gateway-url', 'ab-test-id']:
        delete_param(param)
    print('SSM parameters cleaned up')

    print('\nCleanup complete.')


if __name__ == '__main__':
    main()
