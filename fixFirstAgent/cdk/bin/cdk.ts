#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { BaseStackProps } from '../lib/types';
import { AgentCoreStack } from '../lib/stacks';

const app = new cdk.App();
const deploymentProps: BaseStackProps = {
  appName: "fixFirstAgent",
}

const cloudfrontUrl = app.node.tryGetContext('cloudfrontUrl') || '';

const agentCoreStack = new AgentCoreStack(app, `fixFirstAgent-AgentCoreStack`, {
  ...deploymentProps,
  cloudfrontUrl: cloudfrontUrl || undefined,
});
