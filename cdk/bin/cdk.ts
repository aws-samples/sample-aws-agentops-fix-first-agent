#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { WebHostingStack } from '../lib/web-hosting-stack';
import { BaseStackProps } from '../lib/types';

const app = new cdk.App();

const deploymentProps: BaseStackProps = {
  appName: 'fixFirstAgent',
};

new WebHostingStack(app, 'fixFirstAgent-WebHostingStack', {
  ...deploymentProps,
});
