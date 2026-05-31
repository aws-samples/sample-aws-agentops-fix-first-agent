import * as cdk from 'aws-cdk-lib/core';
import { Construct } from 'constructs/lib/construct';
import * as bedrockagentcore from 'aws-cdk-lib/aws-bedrockagentcore';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import * as s3_assets from 'aws-cdk-lib/aws-s3-assets';
import * as path from 'path';

export interface ABTestingStackProps extends cdk.StackProps {
    appName: string;
}

/**
 * Single stack that deploys:
 * - Two AgentCore Runtimes (control + treatment) with zip artifacts
 * - Two Online Evaluation Configs (one per variant, Builtin.Helpfulness)
 * - IAM roles for runtimes, evaluator, and gateway
 * - SSM parameters for all resource ARNs/IDs
 *
 * The eval configs reference the runtime IDs directly via CloudFormation tokens,
 * so no multi-step deployment or context parameters are needed.
 */
export class ABTestingStack extends cdk.Stack {
    constructor(scope: Construct, id: string, props: ABTestingStackProps) {
        super(scope, id, props);

        const region = cdk.Stack.of(this).region;
        const accountId = cdk.Stack.of(this).account;
        const controlAgentName = 'fixFirstAgent_Agent';
        const refinedAgentName = 'fixFirstAgentRefined_Agent';

        /*****************************
        * Shared IAM policy statements for runtimes
        ******************************/

        const sharedStatements = [
            new iam.PolicyStatement({
                actions: ['logs:CreateLogGroup', 'logs:DescribeLogStreams', 'logs:DescribeLogGroups'],
                resources: [`arn:aws:logs:${region}:${accountId}:log-group:*`],
            }),
            new iam.PolicyStatement({
                actions: ['logs:CreateLogStream', 'logs:PutLogEvents'],
                resources: [`arn:aws:logs:${region}:${accountId}:log-group:/aws/bedrock-agentcore/runtimes/*:log-stream:*`],
            }),
            new iam.PolicyStatement({
                actions: ['bedrock:InvokeModel', 'bedrock:InvokeModelWithResponseStream'],
                resources: [
                    'arn:aws:bedrock:*::foundation-model/amazon.nova-*',
                    'arn:aws:bedrock:*::foundation-model/anthropic.claude-*',
                    `arn:aws:bedrock:${region}:${accountId}:inference-profile/*`,
                ],
            }),
            new iam.PolicyStatement({
                actions: ['xray:PutTraceSegments', 'xray:PutTelemetryRecords'],
                resources: ['*'],
            }),
        ];

        /*****************************
        * Control Agent Runtime
        ******************************/

        const controlCodeAsset = new s3_assets.Asset(this, 'ControlAgentCode', {
            path: path.join(__dirname, '../../agents/control/build'),
        });

        const controlRuntimeRole = new iam.Role(this, 'ControlRuntimeRole', {
            assumedBy: new iam.ServicePrincipal('bedrock-agentcore.amazonaws.com'),
            inlinePolicies: {
                RuntimePolicy: new iam.PolicyDocument({
                    statements: [
                        new iam.PolicyStatement({
                            actions: ['s3:GetObject'],
                            resources: [controlCodeAsset.bucket.arnForObjects('*')],
                        }),
                        ...sharedStatements,
                    ],
                }),
            },
        });

        const controlRuntime = new bedrockagentcore.CfnRuntime(this, 'ControlRuntime', {
            agentRuntimeArtifact: {
                codeConfiguration: {
                    code: {
                        s3: {
                            bucket: controlCodeAsset.s3BucketName,
                            prefix: controlCodeAsset.s3ObjectKey,
                        },
                    },
                    entryPoint: ['opentelemetry-instrument', 'main.py'],
                    runtime: 'PYTHON_3_12',
                },
            },
            agentRuntimeName: controlAgentName,
            protocolConfiguration: 'HTTP',
            networkConfiguration: { networkMode: 'PUBLIC' },
            roleArn: controlRuntimeRole.roleArn,
            requestHeaderConfiguration: {
                requestHeaderAllowlist: ['baggage', 'traceparent'],
            },
        });

        /*****************************
        * Treatment Agent Runtime
        ******************************/

        const refinedCodeAsset = new s3_assets.Asset(this, 'RefinedAgentCode', {
            path: path.join(__dirname, '../../agents/treatment/build'),
        });

        const refinedRuntimeRole = new iam.Role(this, 'RefinedRuntimeRole', {
            assumedBy: new iam.ServicePrincipal('bedrock-agentcore.amazonaws.com'),
            inlinePolicies: {
                RuntimePolicy: new iam.PolicyDocument({
                    statements: [
                        new iam.PolicyStatement({
                            actions: ['s3:GetObject'],
                            resources: [refinedCodeAsset.bucket.arnForObjects('*')],
                        }),
                        ...sharedStatements,
                    ],
                }),
            },
        });

        const refinedRuntime = new bedrockagentcore.CfnRuntime(this, 'RefinedRuntime', {
            agentRuntimeArtifact: {
                codeConfiguration: {
                    code: {
                        s3: {
                            bucket: refinedCodeAsset.s3BucketName,
                            prefix: refinedCodeAsset.s3ObjectKey,
                        },
                    },
                    entryPoint: ['opentelemetry-instrument', 'main.py'],
                    runtime: 'PYTHON_3_12',
                },
            },
            agentRuntimeName: refinedAgentName,
            protocolConfiguration: 'HTTP',
            networkConfiguration: { networkMode: 'PUBLIC' },
            roleArn: refinedRuntimeRole.roleArn,
            requestHeaderConfiguration: {
                requestHeaderAllowlist: ['baggage', 'traceparent'],
            },
        });

        /*****************************
        * Online Evaluation IAM Roles
        ******************************/

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

        const gatewayRole = new iam.Role(this, 'GatewayRole', {
            assumedBy: new iam.ServicePrincipal('bedrock-agentcore.amazonaws.com'),
            inlinePolicies: {
                GatewayPolicy: new iam.PolicyDocument({
                    statements: [
                        new iam.PolicyStatement({
                            actions: ['bedrock-agentcore:*'],
                            resources: [`arn:aws:bedrock-agentcore:${region}:${accountId}:*`],
                        }),
                        new iam.PolicyStatement({
                            actions: ['logs:StartQuery', 'logs:GetQueryResults', 'logs:DescribeLogGroups', 'logs:DescribeLogStreams', 'logs:GetLogEvents', 'logs:FilterLogEvents'],
                            resources: ['*'],
                        }),
                    ],
                }),
            },
        });

        /*****************************
        * Online Evaluation Configs
        * (reference runtime IDs directly — resolved by CloudFormation at deploy time)
        ******************************/

        const controlLogGroup = cdk.Fn.join('', [
            '/aws/bedrock-agentcore/runtimes/',
            controlRuntime.attrAgentRuntimeId,
            '-DEFAULT',
        ]);

        const treatmentLogGroup = cdk.Fn.join('', [
            '/aws/bedrock-agentcore/runtimes/',
            refinedRuntime.attrAgentRuntimeId,
            '-DEFAULT',
        ]);

        const controlEval = new bedrockagentcore.CfnOnlineEvaluationConfig(this, 'ControlEval', {
            onlineEvaluationConfigName: 'fixFirstAgent_control_eval',
            description: 'Online eval for control variant',
            rule: { samplingConfig: { samplingPercentage: 100.0 } },
            dataSourceConfig: {
                cloudWatchLogs: {
                    logGroupNames: [controlLogGroup],
                    serviceNames: [`${controlAgentName}.DEFAULT`],
                },
            },
            evaluators: [{ evaluatorId: 'Builtin.Helpfulness' }],
            evaluationExecutionRoleArn: evalRole.roleArn,
            executionStatus: 'ENABLED',
        });

        const treatmentEval = new bedrockagentcore.CfnOnlineEvaluationConfig(this, 'TreatmentEval', {
            onlineEvaluationConfigName: 'fixFirstAgent_treatment_eval',
            description: 'Online eval for treatment variant',
            rule: { samplingConfig: { samplingPercentage: 100.0 } },
            dataSourceConfig: {
                cloudWatchLogs: {
                    logGroupNames: [treatmentLogGroup],
                    serviceNames: [`${refinedAgentName}.DEFAULT`],
                },
            },
            evaluators: [{ evaluatorId: 'Builtin.Helpfulness' }],
            evaluationExecutionRoleArn: evalRole.roleArn,
            executionStatus: 'ENABLED',
        });

        // Eval configs depend on runtimes being created first
        controlEval.addDependency(controlRuntime);
        treatmentEval.addDependency(refinedRuntime);

        /*****************************
        * SSM Parameters & Outputs
        ******************************/

        new ssm.StringParameter(this, 'SSM-ControlRuntimeArn', {
            parameterName: `/${props.appName}/control-runtime-arn`,
            stringValue: controlRuntime.attrAgentRuntimeArn,
        });

        new ssm.StringParameter(this, 'SSM-RefinedRuntimeArn', {
            parameterName: `/${props.appName}/refined-runtime-arn`,
            stringValue: refinedRuntime.attrAgentRuntimeArn,
        });

        new ssm.StringParameter(this, 'SSM-ControlRuntimeId', {
            parameterName: `/${props.appName}/control-runtime-id`,
            stringValue: controlRuntime.attrAgentRuntimeId,
        });

        new ssm.StringParameter(this, 'SSM-RefinedRuntimeId', {
            parameterName: `/${props.appName}/refined-runtime-id`,
            stringValue: refinedRuntime.attrAgentRuntimeId,
        });

        new ssm.StringParameter(this, 'SSM-ControlEvalArn', {
            parameterName: `/${props.appName}/control-eval-arn`,
            stringValue: controlEval.attrOnlineEvaluationConfigArn,
        });

        new ssm.StringParameter(this, 'SSM-TreatmentEvalArn', {
            parameterName: `/${props.appName}/treatment-eval-arn`,
            stringValue: treatmentEval.attrOnlineEvaluationConfigArn,
        });

        new ssm.StringParameter(this, 'SSM-GatewayRoleArn', {
            parameterName: `/${props.appName}/ab-test-gateway-role-arn`,
            stringValue: gatewayRole.roleArn,
        });

        new cdk.CfnOutput(this, 'ControlRuntimeArn', { value: controlRuntime.attrAgentRuntimeArn });
        new cdk.CfnOutput(this, 'RefinedRuntimeArn', { value: refinedRuntime.attrAgentRuntimeArn });
        new cdk.CfnOutput(this, 'ControlEvalArn', { value: controlEval.attrOnlineEvaluationConfigArn });
        new cdk.CfnOutput(this, 'TreatmentEvalArn', { value: treatmentEval.attrOnlineEvaluationConfigArn });
    }
}
