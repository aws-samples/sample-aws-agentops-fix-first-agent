import * as cdk from 'aws-cdk-lib/core';
import { Construct } from 'constructs/lib/construct';
import * as bedrockagentcore from 'aws-cdk-lib/aws-bedrockagentcore';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda'
import * as cognito from 'aws-cdk-lib/aws-cognito';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import * as s3_assets from 'aws-cdk-lib/aws-s3-assets';
import { BaseStackProps } from '../types';
import * as path from 'path';

export interface AgentCoreStackProps extends BaseStackProps {
    cloudfrontUrl?: string;
}

export class AgentCoreStack extends cdk.Stack {
    readonly agentCoreRuntime: bedrockagentcore.CfnRuntime;
    readonly agentCoreGateway: bedrockagentcore.CfnGateway;
    readonly agentCoreMemory: bedrockagentcore.CfnMemory;
    readonly mcpLambda: lambda.Function;

    constructor(scope: Construct, id: string, props: AgentCoreStackProps) {
        super(scope, id, props);

        const region = cdk.Stack.of(this).region;
        const accountId = cdk.Stack.of(this).account;

        /*****************************
        * AgentCore Gateway
        ******************************/

        this.mcpLambda = new lambda.Function(this, `${props.appName}-McpLambda`, {
            runtime: lambda.Runtime.PYTHON_3_12,
            handler: "handler.lambda_handler",
            code: lambda.AssetCode.fromAsset(path.join(__dirname, '../../../mcp/lambda'))
        });

        const agentCoreGatewayRole = new iam.Role(this, `${props.appName}-AgentCoreGatewayRole`, {
            assumedBy: new iam.ServicePrincipal('bedrock-agentcore.amazonaws.com'),
            description: 'IAM role for Bedrock AgentCore Runtime',
        });

        this.mcpLambda.grantInvoke(agentCoreGatewayRole);

        // Create gateway resource
        // Cognito resources
        const cognitoUserPool = new cognito.UserPool(this, `${props.appName}-CognitoUserPool`,{
            selfSignUpEnabled: true, // Allows users to register themselves
            signInAliases: { 
                username: true,
                email: true }, // Users sign in with their email
            autoVerify: { email: true }, // Automatically send verification emails
            passwordPolicy: {
                minLength: 8,
                requireLowercase: true,
                requireUppercase: true,
                requireDigits: true,
                requireSymbols: true,
            },
            removalPolicy: cdk.RemovalPolicy.DESTROY, 

        });

        const cognitoAppClient = new cognito.UserPoolClient(this, `${props.appName}-CognitoAppClient`, {
            userPool: cognitoUserPool,
            authFlows:{
                userPassword: true,
            },
            supportedIdentityProviders: [cognito.UserPoolClientIdentityProvider.COGNITO],
            oAuth: props.cloudfrontUrl ? {
                callbackUrls: [`${props.cloudfrontUrl}/index.html`],
                logoutUrls: [`${props.cloudfrontUrl}/login.html`],
            } : undefined,
        });
        const cognitoDomain = cognitoUserPool.addDomain(`${props.appName}-CognitoDomain`, {
            cognitoDomain: {
                domainPrefix: `${props.appName.toLowerCase()}-${accountId}-${region}`,
            },
        });
        const cognitoTokenUrl = cognitoDomain.baseUrl() + '/oauth2/token';

        this.agentCoreGateway = new bedrockagentcore.CfnGateway(this, `${props.appName}-AgentCoreGateway`, {
            name: `${props.appName}-Gateway`,
            protocolType: "MCP",
            roleArn: agentCoreGatewayRole.roleArn,
            authorizerType: "CUSTOM_JWT",
            authorizerConfiguration: {
                customJwtAuthorizer: {
                discoveryUrl:
                    'https://cognito-idp.' +
                    region +
                    '.amazonaws.com/' +
                    cognitoUserPool.userPoolId +
                    '/.well-known/openid-configuration',
                allowedClients: [cognitoAppClient.userPoolClientId],
                },
            },
        });

        new bedrockagentcore.CfnGatewayTarget(this, `${props.appName}-AgentCoreGatewayLambdaTarget`, {
            name: `${props.appName}-Target`,
            gatewayIdentifier: this.agentCoreGateway.attrGatewayIdentifier,
            credentialProviderConfigurations: [
                {
                    credentialProviderType: "GATEWAY_IAM_ROLE",
                },
            ],
            targetConfiguration: {
                mcp: {
                    lambda: {
                        lambdaArn: this.mcpLambda.functionArn,
                        toolSchema: {
                            inlinePayload: [
                                {
                                    name: "placeholder_tool",
                                    description: "No-op tool that demonstrates passing arguments",
                                    inputSchema: {
                                        type: "object",
                                        properties: {
                                            string_param: { type: 'string', description: 'Example string parameter' },
                                            int_param: { type: 'integer', description: 'Example integer parameter' },
                                            float_array_param: {
                                                type: 'array',
                                                description: 'Example float array parameter',
                                                items: {
                                                    type: 'number',
                                                }
                                            }
                                        },
                                        required: []
                                    }
                                }
                            ]
                        }
                    }
                }
            }
        })
        
        /*****************************
        * AgentCore Memory
        ******************************/

        this.agentCoreMemory = new bedrockagentcore.CfnMemory(this, `${props.appName}-AgentCoreMemory`, {
            name: "fixFirstAgent_Memory",
            eventExpiryDuration: 30,
            description: "Memory resource with 30 days event expiry",
            memoryStrategies: [
                {semanticMemoryStrategy: {
                    name: `${props.appName}Semantic`,
                    description: `${props.appName}-user semantic memory strategy`,
                    namespaces: ['/users/{actorId}/facts'],
                }},
                {summaryMemoryStrategy: {
                    name: `${props.appName}Summary`,
                    description: `${props.appName}-user Summary memory strategy`,
                    namespaces: ['/summaries/{actorId}/{sessionId}'],
                }},
                {userPreferenceMemoryStrategy: {
                    name: `${props.appName}UserPreference`,
                    description: `${props.appName}-user preference memory strategy`,
                    namespaces: ['/users/{actorId}/preferences'],
                }}

                // can take a built-in strategy from https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/built-in-strategies.html or define a custom one
            ],
        });
        
        /*****************************
        * AgentCore Runtime
        ******************************/

        // Package agent source code as a zip asset uploaded to S3
        // Run `scripts/package-agent.sh` before deploying to bundle dependencies
        const agentCodeAsset = new s3_assets.Asset(this, `${props.appName}-AgentCodeAsset`, {
            path: path.join(__dirname, '../../../build'),
        });

        // taken from https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-permissions.html#runtime-permissions-execution
        const runtimePolicy = new iam.PolicyDocument({
            statements: [
                new iam.PolicyStatement({
                    sid: 'S3CodeAccess',
                    effect: iam.Effect.ALLOW,
                    actions: ['s3:GetObject'],
                    resources: [agentCodeAsset.bucket.arnForObjects('*')],
                }),
                new iam.PolicyStatement({
                    effect: iam.Effect.ALLOW,
                    actions: ['logs:DescribeLogStreams', 'logs:CreateLogGroup'],
                    resources: [
                        `arn:aws:logs:${region}:${accountId}:log-group:/aws/bedrock-agentcore/runtimes/*`,
                    ],
                }),
                new iam.PolicyStatement({
                    effect: iam.Effect.ALLOW,
                    actions: ['logs:DescribeLogGroups'],
                    resources: [
                        `arn:aws:logs:${region}:${accountId}:log-group:*`,
                    ],
                }),
                new iam.PolicyStatement({
                    effect: iam.Effect.ALLOW,
                    actions: ['logs:CreateLogStream', 'logs:PutLogEvents'],
                    resources: [
                        `arn:aws:logs:${region}:${accountId}:log-group:/aws/bedrock-agentcore/runtimes/*:log-stream:*`,
                    ],
                }),
                new iam.PolicyStatement({
                    effect: iam.Effect.ALLOW,
                    actions: [
                        'xray:PutTraceSegments',
                        'xray:PutTelemetryRecords',
                        'xray:GetSamplingRules',
                        'xray:GetSamplingTargets',
                    ],
                resources: ['*'],
                }),
                new iam.PolicyStatement({
                    effect: iam.Effect.ALLOW,
                    actions: ['cloudwatch:PutMetricData'],
                    resources: ['*'],
                    conditions: {
                        StringEquals: { 'cloudwatch:namespace': 'bedrock-agentcore' },
                    },
                }),
                new iam.PolicyStatement({
                    sid: 'GetAgentAccessToken',
                    effect: iam.Effect.ALLOW,
                    actions: [
                        'bedrock-agentcore:GetWorkloadAccessToken',
                        'bedrock-agentcore:GetWorkloadAccessTokenForJWT',
                        'bedrock-agentcore:GetWorkloadAccessTokenForUserId',
                    ],
                    resources: [
                        `arn:aws:bedrock-agentcore:${region}:${accountId}:workload-identity-directory/default`,
                        `arn:aws:bedrock-agentcore:${region}:${accountId}:workload-identity-directory/default/workload-identity/agentName-*`,
                    ],
                }),
                new iam.PolicyStatement({
                    sid: 'BedrockModelInvocation',
                    effect: iam.Effect.ALLOW,
                    actions: ['bedrock:InvokeModel', 'bedrock:InvokeModelWithResponseStream'],
                    resources: [
                        `arn:aws:bedrock:*::foundation-model/amazon.nova-*`,
                        `arn:aws:bedrock:*::foundation-model/anthropic.claude-*`,
                        `arn:aws:bedrock:${region}:${accountId}:inference-profile/*`,
                    ],
                }),
                new iam.PolicyStatement({
                    sid: 'BedrockMemory',
                    effect: iam.Effect.ALLOW,
                    actions: [
                        'bedrock-agentcore:GetMemory',
                        'bedrock-agentcore:CreateEvent',
                        'bedrock-agentcore:GetEvent',
                        'bedrock-agentcore:DeleteEvent',
                        'bedrock-agentcore:ListEvents',
                        'bedrock-agentcore:ListSessions',
                        'bedrock-agentcore:ListActors',
                        'bedrock-agentcore:GetMemoryRecord',
                        'bedrock-agentcore:ListMemoryRecords',
                        'bedrock-agentcore:RetrieveMemoryRecords',
                        'bedrock-agentcore:StartMemoryExtractionJob',
                        'bedrock-agentcore:ListMemoryExtractionJobs',
                        'bedrock-agentcore:InvokeGateway',
                    ],
                    resources: [`arn:aws:bedrock-agentcore:${region}:${accountId}:*`]     
                }),
            ],
        });

        const runtimeRole = new iam.Role(this, `${props.appName}-AgentCoreRuntimeRole`, {
            assumedBy: new iam.ServicePrincipal('bedrock-agentcore.amazonaws.com'),
            description: 'IAM role for Bedrock AgentCore Runtime',
            inlinePolicies: {
                RuntimeAccessPolicy: runtimePolicy
            }
        });

        this.agentCoreRuntime = new bedrockagentcore.CfnRuntime(this, `${props.appName}-AgentCoreRuntime`, {
            agentRuntimeArtifact: {
                codeConfiguration: {
                    code: {
                        s3: {
                            bucket: agentCodeAsset.s3BucketName,
                            prefix: agentCodeAsset.s3ObjectKey,
                        },
                    },
                    entryPoint: ['main.py'],
                    runtime: 'PYTHON_3_12',
                },
            },
            agentRuntimeName: "fixFirstAgent_Agent",
            protocolConfiguration: "HTTP",
            networkConfiguration: {
                networkMode: "PUBLIC"
            },
            roleArn: runtimeRole.roleArn,
            requestHeaderConfiguration: {
                requestHeaderAllowlist: ["X-Amzn-Bedrock-AgentCore-Runtime-Custom-User-Id"]
            },
            authorizerConfiguration:{
                customJwtAuthorizer:{
                    discoveryUrl:`https://cognito-idp.${region}.amazonaws.com/${cognitoUserPool.userPoolId}/.well-known/openid-configuration`,
                    allowedClients: [cognitoAppClient.userPoolClientId]
                }
            },
            environmentVariables: {
                "AWS_REGION": region,
                "GATEWAY_URL": this.agentCoreGateway.attrGatewayUrl,
                "MEMORY_ID":  this.agentCoreMemory.attrMemoryId,
                "COGNITO_CLIENT_ID": cognitoAppClient.userPoolClientId,
                "COGNITO_TOKEN_URL": cognitoTokenUrl
            }
        });

        // DEFAULT endpoint always points to newest published version. Optionally, can use these versioned endpoints below
        // https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/agent-runtime-versioning.html
        void new bedrockagentcore.CfnRuntimeEndpoint(this, `${props.appName}-AgentCoreRuntimeProdEndpoint`, {
            agentRuntimeId: this.agentCoreRuntime.attrAgentRuntimeId,
            agentRuntimeVersion: "1",
            name: "PROD"
        });

        void new bedrockagentcore.CfnRuntimeEndpoint(this, `${props.appName}-AgentCoreRuntimeDevEndpoint`, {
            agentRuntimeId: this.agentCoreRuntime.attrAgentRuntimeId,
            agentRuntimeVersion: "1",
            name: "DEV"
        });

        /*****************************
        * SSM Parameters & Outputs
        ******************************/

        new ssm.StringParameter(this, `${props.appName}-SSM-CognitoUserPoolId`, {
            parameterName: `/${props.appName}/cognito-user-pool-id`,
            stringValue: cognitoUserPool.userPoolId,
        });

        new ssm.StringParameter(this, `${props.appName}-SSM-CognitoClientId`, {
            parameterName: `/${props.appName}/cognito-client-id`,
            stringValue: cognitoAppClient.userPoolClientId,
        });

        new ssm.StringParameter(this, `${props.appName}-SSM-AgentCoreRuntimeArn`, {
            parameterName: `/${props.appName}/agentcore-runtime-arn`,
            stringValue: this.agentCoreRuntime.attrAgentRuntimeArn,
        });

        new ssm.StringParameter(this, `${props.appName}-SSM-Region`, {
            parameterName: `/${props.appName}/region`,
            stringValue: region,
        });

        new cdk.CfnOutput(this, 'CognitoUserPoolId', {
            value: cognitoUserPool.userPoolId,
            exportName: `${props.appName}-CognitoUserPoolId`,
        });

        new cdk.CfnOutput(this, 'CognitoClientId', {
            value: cognitoAppClient.userPoolClientId,
            exportName: `${props.appName}-CognitoClientId`,
        });

        new cdk.CfnOutput(this, 'AgentCoreRuntimeArn', {
            value: this.agentCoreRuntime.attrAgentRuntimeArn,
            exportName: `${props.appName}-AgentCoreRuntimeArn`,
        });
    }
}