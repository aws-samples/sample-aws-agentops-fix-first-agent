#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { ABTestingStack } from '../lib/ab-testing-stack';

const app = new cdk.App();
new ABTestingStack(app, 'fixFirstAgent-ABTestingStack', { appName: 'fixFirstAgent' });
app.synth();
