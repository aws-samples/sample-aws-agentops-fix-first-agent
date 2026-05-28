import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as apigateway from 'aws-cdk-lib/aws-apigateway';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as path from 'path';

export interface StandaloneProxyStackProps extends cdk.StackProps {
  appName: string;
  /** ARN of the AgentCore Runtime to proxy to */
  agentRuntimeArn: string;
  /** Cognito User Pool ID for context (token is passed through to AgentCore) */
  cognitoUserPoolId: string;
  /** Region where Cognito lives */
  cognitoRegion: string;
}

/**
 * Standalone Proxy Stack
 *
 * Deploys just API Gateway + Lambda proxy — no custom domain, no Route 53.
 * Use this to test the proxy layer before setting up multi-region routing.
 *
 * The API Gateway URL is the endpoint you call directly.
 */
export class StandaloneProxyStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: StandaloneProxyStackProps) {
    super(scope, id, props);

    const region = cdk.Stack.of(this).region;

    // ─── Lambda Proxy Function ───────────────────────────────────────────

    const proxyFunction = new lambda.Function(this, 'ProxyFunction', {
      functionName: `${props.appName}-agentcore-proxy`,
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'proxy_handler.handler',
      code: lambda.Code.fromAsset(path.join(__dirname, '../../../lambda')),
      timeout: cdk.Duration.seconds(120),
      memorySize: 256,
      environment: {
        AGENT_RUNTIME_ARN: props.agentRuntimeArn,
        COGNITO_USER_POOL_ID: props.cognitoUserPoolId,
        COGNITO_REGION: props.cognitoRegion,
      },
      logRetention: logs.RetentionDays.ONE_WEEK,
    });

    // Grant the Lambda permission to invoke AgentCore Runtime
    proxyFunction.addToRolePolicy(
      new iam.PolicyStatement({
        effect: iam.Effect.ALLOW,
        actions: ['bedrock-agentcore:InvokeAgentRuntime'],
        resources: [props.agentRuntimeArn],
      })
    );

    // ─── API Gateway ─────────────────────────────────────────────────────

    const api = new apigateway.RestApi(this, 'ProxyApi', {
      restApiName: `${props.appName}-proxy`,
      description: `Proxy for ${props.appName} AgentCore Runtime (standalone test)`,
      endpointTypes: [apigateway.EndpointType.REGIONAL],
      deployOptions: {
        stageName: 'v1',
        throttlingRateLimit: 100,
        throttlingBurstLimit: 200,
      },
      defaultCorsPreflightOptions: {
        allowOrigins: apigateway.Cors.ALL_ORIGINS,
        allowMethods: ['POST', 'OPTIONS'],
        allowHeaders: [
          'Content-Type',
          'Authorization',
          'X-Amzn-Trace-Id',
          'X-Session-Id',
          'X-User-Id',
        ],
      },
    });

    // POST /invoke — main agent invocation endpoint
    const invokeResource = api.root.addResource('invoke');
    invokeResource.addMethod(
      'POST',
      new apigateway.LambdaIntegration(proxyFunction, { proxy: true })
    );

    // GET /health — simple health check
    const healthResource = api.root.addResource('health');
    healthResource.addMethod(
      'GET',
      new apigateway.MockIntegration({
        integrationResponses: [
          {
            statusCode: '200',
            responseTemplates: {
              'application/json': JSON.stringify({
                status: 'healthy',
                region: region,
              }),
            },
          },
        ],
        requestTemplates: {
          'application/json': '{"statusCode": 200}',
        },
      }),
      {
        methodResponses: [
          {
            statusCode: '200',
            responseModels: { 'application/json': apigateway.Model.EMPTY_MODEL },
          },
        ],
      }
    );

    // ─── Outputs ─────────────────────────────────────────────────────────

    new cdk.CfnOutput(this, 'InvokeUrl', {
      value: `${api.url}invoke`,
      description: 'POST to this URL to invoke the agent via the proxy',
    });

    new cdk.CfnOutput(this, 'HealthUrl', {
      value: `${api.url}health`,
      description: 'GET this URL to check the proxy health',
    });
  }
}
