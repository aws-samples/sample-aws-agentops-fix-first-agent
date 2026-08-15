import * as cdk from 'aws-cdk-lib/core';
import { Construct } from 'constructs/lib/construct';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as logsDestinations from 'aws-cdk-lib/aws-logs-destinations';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import { BaseStackProps } from '../types';
import * as path from 'path';

export interface ShadowTrafficStackProps extends BaseStackProps {
    /** The AgentCore runtime ID (e.g., "abc123"). Used to construct the PROD log group name. */
    runtimeId: string;
    /** The AgentCore runtime ARN. Passed to Lambda as env var for invoking PREPROD. */
    runtimeArn: string;
    /** Cognito app client ID for authenticating shadow requests. */
    cognitoClientId: string;
    /** Cognito username for shadow traffic authentication. */
    cognitoUsername: string;
}

export class ShadowTrafficStack extends cdk.Stack {
    constructor(scope: Construct, id: string, props: ShadowTrafficStackProps) {
        super(scope, id, props);

        const region = cdk.Stack.of(this).region;
        const accountId = cdk.Stack.of(this).account;
        const passwordParamName = `/${props.appName}/shadow-cognito-password`;

        /*****************************
        * Shadow Traffic Lambda
        ******************************/

        const shadowLambda = new lambda.Function(this, `${props.appName}-ShadowLambda`, {
            runtime: lambda.Runtime.PYTHON_3_12,
            handler: 'shadow_lambda.handler',
            code: lambda.Code.fromAsset(path.join(__dirname, '../../../../bluegreen_testing'), {
                exclude: ['*.sh', 'invoke_agent.py'],
            }),
            timeout: cdk.Duration.seconds(60),
            memorySize: 256,
            environment: {
                RUNTIME_ARN: props.runtimeArn,
                SHADOW_ENDPOINT: 'PREPROD',
                COGNITO_CLIENT_ID: props.cognitoClientId,
                COGNITO_USERNAME: props.cognitoUsername,
                COGNITO_PASSWORD_PARAM: passwordParamName,
            },
        });

        // Grant Lambda permission to read the password from SSM
        shadowLambda.addToRolePolicy(new iam.PolicyStatement({
            actions: ['ssm:GetParameter'],
            resources: [`arn:aws:ssm:${region}:${accountId}:parameter${passwordParamName}`],
        }));

        // Grant Lambda permission to authenticate via Cognito
        shadowLambda.addToRolePolicy(new iam.PolicyStatement({
            actions: ['cognito-idp:InitiateAuth'],
            resources: ['*'],
        }));

        /*****************************
        * CloudWatch Subscription Filter
        ******************************/

        const prodLogGroupName = `/aws/bedrock-agentcore/runtimes/${props.runtimeId}-PROD`;

        // Import the existing PROD log group (created by AgentCore when PROD endpoint is first invoked)
        const prodLogGroup = logs.LogGroup.fromLogGroupName(
            this, 'ProdLogGroup', prodLogGroupName
        );

        new logs.SubscriptionFilter(this, `${props.appName}-ShadowSubscription`, {
            logGroup: prodLogGroup,
            destination: new logsDestinations.LambdaDestination(shadowLambda),
            filterPattern: logs.FilterPattern.literal('"User Input:"'),
            filterName: 'shadow-to-preprod',
        });

        /*****************************
        * SSM Parameter (placeholder — participant sets the value via CLI)
        ******************************/

        // NOTE: The Cognito password is stored as SecureString via deploy_shadow.sh.
        // CDK cannot create SecureString parameters directly, so we create a String
        // placeholder that deploy_shadow.sh overwrites as SecureString before first use.
        new ssm.StringParameter(this, `${props.appName}-SSM-ShadowPassword`, {
            parameterName: passwordParamName,
            stringValue: 'PLACEHOLDER-run-deploy_shadow.sh-to-set',
            description: 'Cognito password for shadow traffic Lambda (overwritten as SecureString by deploy_shadow.sh)',
        });

        /*****************************
        * Outputs
        ******************************/

        new cdk.CfnOutput(this, 'ShadowLambdaName', {
            value: shadowLambda.functionName,
            exportName: `${props.appName}-ShadowLambdaName`,
        });

        new cdk.CfnOutput(this, 'ProdLogGroup', {
            value: prodLogGroupName,
            exportName: `${props.appName}-ProdLogGroup`,
        });
    }
}
