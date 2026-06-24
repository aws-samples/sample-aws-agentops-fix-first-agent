import * as cdk from 'aws-cdk-lib/core';
import { Construct } from 'constructs/lib/construct';
import * as bedrockagentcore from 'aws-cdk-lib/aws-bedrockagentcore';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as ssm from 'aws-cdk-lib/aws-ssm';

/**
 * Deploys online evaluation config for fixFirstAgent.
 * Reads runtime ARN from SSM (deployed by the agent CDK stack).
 */
export class EvaluationsStack extends cdk.Stack {
    constructor(scope: Construct, id: string, props?: cdk.StackProps) {
        super(scope, id, props);

        const region = cdk.Stack.of(this).region;
        const appName = 'fixFirstAgent';

        // Read runtime ARN from SSM (created by agent CDK stack)
        const runtimeArn = ssm.StringParameter.valueForStringParameter(
            this, `/${appName}/agentcore-runtime-arn`
        );
        // Extract runtime ID from ARN: arn:aws:bedrock-agentcore:region:account:runtime/ID
        const runtimeId = cdk.Fn.select(1, cdk.Fn.split('runtime/', runtimeArn));

        const logGroup = cdk.Fn.join('', [
            '/aws/bedrock-agentcore/runtimes/', runtimeId, '-DEFAULT',
        ]);

        // IAM role for evaluation
        const evalRole = new iam.Role(this, 'EvalRole', {
            assumedBy: new iam.ServicePrincipal('bedrock-agentcore.amazonaws.com'),
            inlinePolicies: {
                EvalPolicy: new iam.PolicyDocument({
                    statements: [
                        new iam.PolicyStatement({
                            actions: [
                                'logs:GetLogEvents', 'logs:FilterLogEvents',
                                'logs:DescribeLogGroups', 'logs:DescribeLogStreams',
                                'logs:StartQuery', 'logs:GetQueryResults',
                                'logs:CreateLogGroup', 'logs:CreateLogStream', 'logs:PutLogEvents',
                            ],
                            resources: ['*'],
                        }),
                        new iam.PolicyStatement({
                            actions: ['bedrock:InvokeModel'],
                            resources: ['*'],
                        }),
                    ],
                }),
            },
        });

        // Online evaluation config
        const onlineEval = new bedrockagentcore.CfnOnlineEvaluationConfig(this, 'OnlineEval', {
            onlineEvaluationConfigName: `${appName}_online_eval`,
            description: 'Online evaluation with Helpfulness and GoalSuccessRate',
            rule: { samplingConfig: { samplingPercentage: 100.0 } },
            dataSourceConfig: {
                cloudWatchLogs: {
                    logGroupNames: [logGroup],
                    serviceNames: [`${appName}_Agent.DEFAULT`],
                },
            },
            evaluators: [
                { evaluatorId: 'Builtin.Helpfulness' },
                { evaluatorId: 'Builtin.Correctness' },
                { evaluatorId: 'Builtin.ResponseRelevance' },
            ],
            evaluationExecutionRoleArn: evalRole.roleArn,
            executionStatus: 'ENABLED',
        });

        // SSM parameter for eval config ID
        new ssm.StringParameter(this, 'SSM-OnlineEvalConfigId', {
            parameterName: `/${appName}/online-eval-config-id`,
            stringValue: onlineEval.attrOnlineEvaluationConfigId,
        });

        new cdk.CfnOutput(this, 'OnlineEvalConfigId', {
            value: onlineEval.attrOnlineEvaluationConfigId,
        });
    }
}
