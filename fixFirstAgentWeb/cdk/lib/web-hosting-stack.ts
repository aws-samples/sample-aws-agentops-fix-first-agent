import * as cdk from 'aws-cdk-lib/core';
import { Construct } from 'constructs';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as s3deploy from 'aws-cdk-lib/aws-s3-deployment';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as cloudfront_origins from 'aws-cdk-lib/aws-cloudfront-origins';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import * as path from 'path';
import { BaseStackProps } from './types';

export interface WebHostingStackProps extends BaseStackProps {}

export class WebHostingStack extends cdk.Stack {
  readonly distribution: cloudfront.Distribution;
  readonly websiteBucket: s3.Bucket;

  constructor(scope: Construct, id: string, props: WebHostingStackProps) {
    super(scope, id, props);

    // S3 bucket for static website
    this.websiteBucket = new s3.Bucket(this, `${props.appName}-WebBucket`, {
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
    });

    // CloudFront Origin Access Identity
    const oai = new cloudfront.OriginAccessIdentity(this, `${props.appName}-OAI`);
    this.websiteBucket.grantRead(oai);

    // Security response headers
    const responseHeadersPolicy = new cloudfront.ResponseHeadersPolicy(this, `${props.appName}-SecurityHeaders`, {
      securityHeadersBehavior: {
        contentSecurityPolicy: {
          contentSecurityPolicy: "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self' https://*.amazonaws.com; img-src 'self' data:; font-src 'self';",
          override: true,
        },
        contentTypeOptions: { override: true },
        frameOptions: { frameOption: cloudfront.HeadersFrameOption.DENY, override: true },
        referrerPolicy: { referrerPolicy: cloudfront.HeadersReferrerPolicy.STRICT_ORIGIN_WHEN_CROSS_ORIGIN, override: true },
        strictTransportSecurity: { accessControlMaxAge: cdk.Duration.days(365), includeSubdomains: true, override: true },
        xssProtection: { protection: true, modeBlock: true, override: true },
      },
    });

    // CloudFront distribution
    this.distribution = new cloudfront.Distribution(this, `${props.appName}-Distribution`, {
      defaultBehavior: {
        origin: new cloudfront_origins.S3Origin(this.websiteBucket, {
          originAccessIdentity: oai,
        }),
        viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
        responseHeadersPolicy,
      },
      defaultRootObject: 'index.html',
      errorResponses: [
        {
          httpStatus: 404,
          responseHttpStatus: 200,
          responsePagePath: '/index.html', // SPA fallback
        },
        {
          httpStatus: 403,
          responseHttpStatus: 200,
          responsePagePath: '/index.html',
        },
      ],
    });

    // Deploy static website files
    new s3deploy.BucketDeployment(this, `${props.appName}-DeployWebsite`, {
      sources: [s3deploy.Source.asset(path.join(__dirname, '../../static'))],
      destinationBucket: this.websiteBucket,
      distribution: this.distribution,
      distributionPaths: ['/*'],
    });

    // Store CloudFront URL in SSM (the other params are written by AgentCoreStack)
    new ssm.StringParameter(this, `${props.appName}-SSM-CloudFrontUrl`, {
      parameterName: `/${props.appName}/cloudfront-url`,
      stringValue: `https://${this.distribution.distributionDomainName}`,
    });

    // Outputs
    new cdk.CfnOutput(this, 'WebsiteURL', {
      value: `https://${this.distribution.distributionDomainName}`,
      description: 'CloudFront distribution URL',
    });

    new cdk.CfnOutput(this, 'BucketName', {
      value: this.websiteBucket.bucketName,
      description: 'S3 bucket name',
    });

    new cdk.CfnOutput(this, 'DistributionId', {
      value: this.distribution.distributionId,
      description: 'CloudFront distribution ID',
    });
  }
}
