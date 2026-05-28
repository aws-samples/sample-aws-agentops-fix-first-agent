import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as apigateway from 'aws-cdk-lib/aws-apigateway';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as acm from 'aws-cdk-lib/aws-certificatemanager';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import * as path from 'path';

export interface RegionalProxyStackProps extends cdk.StackProps {
  appName: string;
  /** ARN of the AgentCore Runtime in this region */
  agentRuntimeArn: string;
  /** Custom domain name for the API (e.g., api.fixfirst.example.com) */
  customDomainName: string;
  /** ACM certificate ARN in this region for the custom domain */
  certificateArn: string;
  /** Cognito User Pool ID (single region, shared across both) */
  cognitoUserPoolId: string;
  /** Region where Cognito lives */
  cognitoRegion: string;
}

/**
 * Regional Proxy Stack
 *
 * Deploys an API Gateway + Lambda proxy in a single region.
 * The Lambda function forwards requests to the local AgentCore Runtime.
 * The API Gateway is configured with a custom domain name so Route 53
 * can route traffic to it via failover records.
 */
export class RegionalProxyStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: RegionalProxyStackProps) {
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
      restApiName: `${props.appName}-multi-region-proxy`,
      description: `Multi-region proxy for ${props.appName} AgentCore Runtime`,
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
      new apigateway.LambdaIntegration(proxyFunction, {
        proxy: true,
        integrationResponses: [{ statusCode: '200' }],
      })
    );

    // GET /health — health check endpoint for Route 53 or monitoring
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
                timestamp: '$context.requestTime',
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
            responseModels: {
              'application/json': apigateway.Model.EMPTY_MODEL,
            },
          },
        ],
      }
    );

    // ─── Custom Domain ───────────────────────────────────────────────────

    const certificate = acm.Certificate.fromCertificateArn(
      this,
      'DomainCert',
      props.certificateArn
    );

    const customDomain = new apigateway.DomainName(this, 'CustomDomain', {
      domainName: props.customDomainName,
      certificate,
      endpointType: apigateway.EndpointType.REGIONAL,
      securityPolicy: apigateway.SecurityPolicy.TLS_1_2,
    });

    // Map the custom domain to the API
    new apigateway.BasePathMapping(this, 'BasePathMapping', {
      domainName: customDomain,
      restApi: api,
      stage: api.deploymentStage,
    });

    // ─── Outputs ─────────────────────────────────────────────────────────

    // Store in SSM so the RoutingStack (potentially in another region) can read them
    new ssm.StringParameter(this, 'SSM-ApiRegionalDomainName', {
      parameterName: `/${props.appName}/multi-region/api-regional-domain-name`,
      stringValue: customDomain.domainNameAliasDomainName,
      description: 'API Gateway custom domain regional DNS name (for Route 53 alias)',
    });

    new ssm.StringParameter(this, 'SSM-ApiRegionalHostedZoneId', {
      parameterName: `/${props.appName}/multi-region/api-regional-hosted-zone-id`,
      stringValue: customDomain.domainNameAliasHostedZoneId,
      description: 'API Gateway custom domain hosted zone ID (for Route 53 alias)',
    });

    new cdk.CfnOutput(this, 'ApiGatewayUrl', {
      value: api.url,
      description: 'API Gateway URL (direct, not via custom domain)',
    });

    new cdk.CfnOutput(this, 'CustomDomainRegionalTarget', {
      value: customDomain.domainNameAliasDomainName,
      description: 'Regional domain name for Route 53 alias target',
    });

    new cdk.CfnOutput(this, 'CustomDomainHostedZoneId', {
      value: customDomain.domainNameAliasHostedZoneId,
      description: 'Hosted zone ID for Route 53 alias target',
    });
  }
}
