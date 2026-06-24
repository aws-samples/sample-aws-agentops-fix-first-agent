"""Cleanup configuration-based A/B test resources.

Deletes: A/B test, config bundles, eval config, gateway target, gateway, IAM role, SSM params.
"""
import boto3
import os
import time
import uuid

REGION = os.environ.get('AWS_REGION', os.environ.get('CDK_DEFAULT_REGION', 'us-east-1'))
APP_NAME = os.environ.get('APP_NAME', 'fixFirstAgent')

ssm_client = boto3.client('ssm', region_name=REGION)
cp_client = boto3.client('bedrock-agentcore-control', region_name=REGION)
dp_client = boto3.client('bedrock-agentcore', region_name=REGION)
iam_client = boto3.client('iam', region_name=REGION)


def get_param(name):
    try:
        return ssm_client.get_parameter(Name=f'/{APP_NAME}/{name}')['Parameter']['Value']
    except:
        return None


def main():
    print(f'Region: {REGION}, App: {APP_NAME}')

    ab_test_id = get_param('config-ab-test-id')
    gateway_id = get_param('config-ab-gateway-id')

    # Stop and delete A/B test
    if ab_test_id:
        try:
            dp_client.update_ab_test(abTestId=ab_test_id, executionStatus='STOPPED', clientToken=str(uuid.uuid4()))
            print(f'A/B test stopped: {ab_test_id}')
            time.sleep(10)
        except Exception as e:
            print(f'Stop A/B test: {e}')
        try:
            dp_client.delete_ab_test(abTestId=ab_test_id)
            print(f'A/B test deleted: {ab_test_id}')
        except Exception as e:
            print(f'Delete A/B test: {e}')

    # Delete gateway target and gateway
    if gateway_id:
        try:
            targets = cp_client.list_gateway_targets(gatewayIdentifier=gateway_id).get('items', [])
            for t in targets:
                cp_client.delete_gateway_target(gatewayIdentifier=gateway_id, targetId=t['targetId'])
                print(f'Target deleted: {t["name"]}')
            if targets:
                time.sleep(10)
        except Exception as e:
            print(f'Delete targets: {e}')
        try:
            cp_client.delete_gateway(gatewayIdentifier=gateway_id)
            print(f'Gateway deleted: {gateway_id}')
        except Exception as e:
            print(f'Delete gateway: {e}')

    # Delete eval config
    eval_arn = get_param('config-ab-eval-arn')
    if eval_arn:
        try:
            eval_id = eval_arn.split('/')[-1]
            cp_client.delete_online_evaluation_config(onlineEvaluationConfigId=eval_id)
            print(f'Eval config deleted: {eval_id}')
        except Exception as e:
            print(f'Delete eval config: {e}')

    # Delete config bundles
    for param_name in ['config-ab-control-bundle-arn', 'config-ab-treatment-bundle-arn']:
        bundle_arn = get_param(param_name)
        if bundle_arn:
            try:
                bundle_id = bundle_arn.split('/')[-1]
                cp_client.delete_configuration_bundle(configurationBundleId=bundle_id)
                print(f'Config bundle deleted: {bundle_id}')
            except Exception as e:
                print(f'Delete bundle: {e}')

    # Delete IAM role
    role_name = f'{APP_NAME}-ConfigABGatewayRole'
    try:
        iam_client.delete_role_policy(RoleName=role_name, PolicyName='GatewayPolicy')
        iam_client.delete_role(RoleName=role_name)
        print(f'IAM role deleted: {role_name}')
    except Exception as e:
        print(f'Delete IAM role: {e}')

    # Clean SSM params
    for param in ['config-ab-gateway-id', 'config-ab-gateway-url', 'config-ab-test-id',
                  'config-ab-eval-arn', 'config-ab-control-bundle-arn', 'config-ab-treatment-bundle-arn']:
        try:
            ssm_client.delete_parameter(Name=f'/{APP_NAME}/{param}')
        except:
            pass
    print('SSM parameters cleaned up')
    print('\nCleanup complete.')


if __name__ == '__main__':
    main()
