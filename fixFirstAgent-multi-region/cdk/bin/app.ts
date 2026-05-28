#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { PrerequisitesStack } from '../lib/stacks/prerequisites-stack';
import { RegionalProxyStack } from '../lib/stacks/regional-proxy-stack';
import { RoutingStack } from '../lib/stacks/routing-stack';
import { StandaloneProxyStack } from '../lib/stacks/standalone-proxy-stack';

const app = new cdk.App();

// ============================================================
// CONFIGURATION
//
// Replace placeholder values below with your actual values.
// Values can also be passed via CDK context (-c key=value).
// ============================================================

const appName = 'fixFirstAgent';

// ─── Domain Configuration ────────────────────────────────────────────
// PLACEHOLDER: Replace with your actual domain
const domainName = app.node.tryGetContext('domainName') || 'api.fixfirst.example.com';
const hostedZoneName = app.node.tryGetContext('hostedZoneName') || 'fixfirst.example.com';

// If you already have a Route 53 hosted zone, put its ID here.
// Leave empty to create a new one (you'll need to update NS records at your registrar).
const existingHostedZoneId = app.node.tryGetContext('existingHostedZoneId') || '';

// ─── Region Configuration ────────────────────────────────────────────
const primaryRegion = app.node.tryGetContext('primaryRegion') || 'us-east-1';
const secondaryRegion = app.node.tryGetContext('secondaryRegion') || 'us-west-2';

// ─── AgentCore Runtime ARNs ──────────────────────────────────────────
// PLACEHOLDER: Replace with ARNs from your existing fixFirstAgent deployments
const primaryAgentRuntimeArn =
  app.node.tryGetContext('primaryAgentRuntimeArn') ||
  'arn:aws:bedrock-agentcore:us-east-1:ACCOUNT_ID:runtime/RUNTIME_ID';
const secondaryAgentRuntimeArn =
  app.node.tryGetContext('secondaryAgentRuntimeArn') ||
  'arn:aws:bedrock-agentcore:us-west-2:ACCOUNT_ID:runtime/RUNTIME_ID';

// ─── Cognito Configuration ───────────────────────────────────────────
// Single Cognito pool shared across regions (tokens validated via OIDC discovery)
// PLACEHOLDER: Replace with your Cognito User Pool ID
const cognitoUserPoolId = app.node.tryGetContext('cognitoUserPoolId') || 'us-east-1_XXXXXXXXX';
const cognitoRegion = app.node.tryGetContext('cognitoRegion') || primaryRegion;

// ─── Certificate ARNs (populated after PrerequisitesStack deploys) ───
// After deploying prerequisites in both regions, retrieve these from SSM or stack outputs.
// Leave empty on first deploy — the deploy script reads them from SSM automatically.
const primaryCertificateArn = app.node.tryGetContext('primaryCertificateArn') || '';
const secondaryCertificateArn = app.node.tryGetContext('secondaryCertificateArn') || '';

// ─── API Gateway Outputs (populated after RegionalProxyStack deploys) ─
// These are read from SSM by the deploy script between phases.
const primaryApiDomainName = app.node.tryGetContext('primaryApiDomainName') || '';
const primaryApiHostedZoneId = app.node.tryGetContext('primaryApiHostedZoneId') || '';
const secondaryApiDomainName = app.node.tryGetContext('secondaryApiDomainName') || '';
const secondaryApiHostedZoneId = app.node.tryGetContext('secondaryApiHostedZoneId') || '';

// Hosted zone ID (populated after PrerequisitesStack deploys)
const hostedZoneId = app.node.tryGetContext('hostedZoneId') || '';

// ============================================================
// STACK DEFINITIONS
//
// Deployment order:
//   1. PrerequisitesStack (both regions) — creates hosted zone + certs
//   2. RegionalProxyStack (both regions) — creates API GW + Lambda proxy
//   3. RoutingStack (primary region) — creates Route 53 failover records
//
// OR for quick testing without a domain:
//   Deploy just StandaloneProxyStack — gives you an API Gateway URL directly.
// ============================================================

// ─── Standalone Proxy (for testing without a custom domain) ──────────
// Deploy with: npx cdk deploy fixFirstAgent-StandaloneProxy
new StandaloneProxyStack(app, `${appName}-StandaloneProxy`, {
  env: {
    region: primaryRegion,
    account: app.node.tryGetContext('account') || process.env.CDK_DEFAULT_ACCOUNT,
  },
  appName,
  agentRuntimeArn: primaryAgentRuntimeArn,
  cognitoUserPoolId,
  cognitoRegion,
});

// ─── Phase 0: Prerequisites (Hosted Zone + ACM Certificates) ─────────

new PrerequisitesStack(app, `${appName}-Prerequisites-Primary`, {
  env: { region: primaryRegion },
  appName,
  domainName,
  hostedZoneName,
  existingHostedZoneId: existingHostedZoneId || undefined,
});

new PrerequisitesStack(app, `${appName}-Prerequisites-Secondary`, {
  env: { region: secondaryRegion },
  appName,
  domainName,
  hostedZoneName,
  existingHostedZoneId: existingHostedZoneId || undefined,
});

// ─── Phase 1: Regional Proxy Stacks ─────────────────────────────────

if (primaryCertificateArn) {
  new RegionalProxyStack(app, `${appName}-RegionalProxy-Primary`, {
    env: { region: primaryRegion },
    appName,
    agentRuntimeArn: primaryAgentRuntimeArn,
    customDomainName: domainName,
    certificateArn: primaryCertificateArn,
    cognitoUserPoolId,
    cognitoRegion,
  });
}

if (secondaryCertificateArn) {
  new RegionalProxyStack(app, `${appName}-RegionalProxy-Secondary`, {
    env: { region: secondaryRegion },
    appName,
    agentRuntimeArn: secondaryAgentRuntimeArn,
    customDomainName: domainName,
    certificateArn: secondaryCertificateArn,
    cognitoUserPoolId,
    cognitoRegion,
  });
}

// ─── Phase 2: Routing Stack (Route 53 Failover) ─────────────────────

if (primaryApiDomainName && secondaryApiDomainName && hostedZoneId) {
  new RoutingStack(app, `${appName}-RoutingStack`, {
    env: { region: primaryRegion },
    appName,
    domainName,
    hostedZoneId,
    hostedZoneName,
    primaryApiDomainName,
    primaryApiHostedZoneId,
    secondaryApiDomainName,
    secondaryApiHostedZoneId,
    primaryRegion,
    secondaryRegion,
  });
}

app.synth();
