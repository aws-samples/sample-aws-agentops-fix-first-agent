#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { ConfigABTestingStack } from '../lib/config-ab-testing-stack';

const app = new cdk.App();
new ConfigABTestingStack(app, 'fixFirstAgent-ConfigABTestingStack', {
    appName: 'fixFirstAgent',
});
app.synth();
