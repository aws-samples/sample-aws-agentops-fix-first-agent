#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { ABGatewayStack } from '../lib/ab-gateway-stack';

const app = new cdk.App();

const controlRuntimeArn = app.node.tryGetContext('controlRuntimeArn') || '';
const refinedRuntimeArn = app.node.tryGetContext('refinedRuntimeArn') || '';
const controlEvalArn = app.node.tryGetContext('controlEvalArn') || '';
const treatmentEvalArn = app.node.tryGetContext('treatmentEvalArn') || '';

new ABGatewayStack(app, 'fixFirstAgent-ABGatewayStack', {
    appName: 'fixFirstAgent',
    controlRuntimeArn,
    refinedRuntimeArn,
    controlEvalArn,
    treatmentEvalArn,
});

app.synth();
