import * as cdk from 'aws-cdk-lib/core';
import { Construct } from 'constructs/lib/construct';
import * as bedrockagentcore from 'aws-cdk-lib/aws-bedrockagentcore';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import * as s3_assets from 'aws-cdk-lib/aws-s3-assets';
import * as path from 'path';

export interface ConfigABTestingStackProps extends cdk.StackProps {
    appName: string;
}

/**
 * Deploys infrastructure for configuration-bundle-based A/B testing:
 * - One AgentCore Runtime (with BeforeModelCallEvent hook for dynamic config)
 * - One shared Online Evaluation Config (Builtin.Helpfulness)
 * - IAM roles for runtime, evaluator, and gateway
 * - SSM parameters for all resource ARNs
 *
 * After this stack deploys, run create_config_ab_test.py to create
 * the configuration bundles and A/B test (not supported by CloudFormation).
 */
export class ConfigABTestingStack extends cdk.Stack {
    constructor(scope: Construct, id: string, props: ConfigABTestingStackProps) {
        super(scope, id, props);

        const region = cdk.Stack.of(this).region;
        const accountId = cdk.Stack.of(this).account;
        const agentName = 'fixFirstAgent_ConfigBundle_Agent';

        // IAM role for the runtime
        const runtimeRole = new iam.Role(this, 'RuntimeRole', {
            assumedBy: new iam.ServicePrincipal('bedrock-agentcore.amazonaws.com'),
            inlinePolicies: {
                RuntimePolicy: new iam.PolicyDocument({
                    statements: [
                        new iam.PolicyStatement({
                            actions: ['s3:GetObject'],
                            resources: ['*'],
                        }),
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
                                `arn:aws:bedrock:${region}:${accountId}:inference-profile/*`,
                            ],
                        }),
                        new iam.PolicyStatement({
                            actions: ['bedrock-agentcore:GetConfigurationBundleVersion'],
                            resources: [`arn:aws:bedrock-agentcore:${region}:${accountId}:configuration-bundle/*`],
                        }),
                        new iam.PolicyStatement({
                            actions: ['xray:PutTraceSegments', 'xray:PutTelemetryRecords'],
                            resources: ['*'],
                        }),
                    ],
                }),
            },
        });

        // Agent code asset
        const codeAsset = new s3_assets.Asset(this, 'AgentCode', {
            path: path.join(__dirname, '../../agent/build'),
        });

        // Runtime
        const runtime = new bedrockagentcore.CfnRuntime(this, 'ConfigRuntime', {
            agentRuntimeArtifact: {
                codeConfiguration: {
                    code: {
                        s3: {
                            bucket: codeAsset.s3BucketName,
                            prefix: codeAsset.s3ObjectKey,
                        },
                    },
                    entryPoint: ['opentelemetry-instrument', 'main.py'],
                    runtime: 'PYTHON_3_12',
                },
            },
            agentRuntimeName: agentName,
            protocolConfiguration: 'HTTP',
            networkConfiguration: { networkMode: 'PUBLIC' },
            roleArn: runtimeRole.roleArn,
            requestHeaderConfiguration: {
                requestHeaderAllowlist: ['baggage', 'traceparent'],
            },
        });

        // IAM role for evaluator and gateway
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
                        new iam.PolicyStatement({
                            actions: ['bedrock-agentcore:*'],
                            resources: [`arn:aws:bedrock-agentcore:${region}:${accountId}:*`],
                        }),
                    ],
                }),
            },
        });

        // Shared online evaluation config
        const logGroup = cdk.Fn.join('', [
            '/aws/bedrock-agentcore/runtimes/',
            runtime.attrAgentRuntimeId,
            '-DEFAULT',
        ]);

        const evalConfig = new bedrockagentcore.CfnOnlineEvaluationConfig(this, 'SharedEval', {
            onlineEvaluationConfigName: `${props.appName}_config_eval`,
            description: 'Shared eval for config bundle A/B test',
            rule: { samplingConfig: { samplingPercentage: 100.0 } },
            dataSourceConfig: {
                cloudWatchLogs: {
                    logGroupNames: [logGroup],
                    serviceNames: [`${agentName}.DEFAULT`],
                },
            },
            evaluators: [{ evaluatorId: 'Builtin.Helpfulness' }],
            evaluationExecutionRoleArn: evalRole.roleArn,
            executionStatus: 'ENABLED',
        });
        evalConfig.addDependency(runtime);

        // SSM Parameters
        new ssm.StringParameter(this, 'SSM-ConfigRuntimeArn', {
            parameterName: `/${props.appName}/config-runtime-arn`,
            stringValue: runtime.attrAgentRuntimeArn,
        });

        new ssm.StringParameter(this, 'SSM-ConfigRuntimeId', {
            parameterName: `/${props.appName}/config-runtime-id`,
            stringValue: runtime.attrAgentRuntimeId,
        });

        new ssm.StringParameter(this, 'SSM-ConfigEvalArn', {
            parameterName: `/${props.appName}/config-eval-arn`,
            stringValue: evalConfig.attrOnlineEvaluationConfigArn,
        });

        new ssm.StringParameter(this, 'SSM-ConfigGatewayRoleArn', {
            parameterName: `/${props.appName}/config-gateway-role-arn`,
            stringValue: evalRole.roleArn,
        });

        // Outputs
        new cdk.CfnOutput(this, 'RuntimeArn', { value: runtime.attrAgentRuntimeArn });
        new cdk.CfnOutput(this, 'EvalArn', { value: evalConfig.attrOnlineEvaluationConfigArn });
    }
}
