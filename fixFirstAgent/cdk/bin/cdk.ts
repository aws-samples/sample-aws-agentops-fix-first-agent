#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { BaseStackProps } from '../lib/types';
import { AgentCoreStack, ShadowTrafficStack } from '../lib/stacks';

const app = new cdk.App();
const deploymentProps: BaseStackProps = {
  appName: "fixFirstAgent",
}

const cloudfrontUrl = app.node.tryGetContext('cloudfrontUrl') || '';

const agentCoreStack = new AgentCoreStack(app, `fixFirstAgent-AgentCoreStack`, {
  ...deploymentProps,
  cloudfrontUrl: cloudfrontUrl || undefined,
});

// Shadow Traffic stack — deployed in Module 5 only.
// Requires context values: runtimeId, runtimeArn, cognitoClientId, cognitoUsername
const runtimeId = app.node.tryGetContext('runtimeId');
const runtimeArn = app.node.tryGetContext('runtimeArn');
const cognitoClientId = app.node.tryGetContext('cognitoClientId');
const cognitoUsername = app.node.tryGetContext('cognitoUsername');

if (runtimeId && runtimeArn && cognitoClientId && cognitoUsername) {
  new ShadowTrafficStack(app, `fixFirstAgent-ShadowTrafficStack`, {
    ...deploymentProps,
    runtimeId,
    runtimeArn,
    cognitoClientId,
    cognitoUsername,
  });
}
