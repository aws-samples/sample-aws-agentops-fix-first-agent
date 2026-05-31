import * as cdk from 'aws-cdk-lib/core';
import { Construct } from 'constructs';
import * as s3_assets from 'aws-cdk-lib/aws-s3-assets';
import * as path from 'path';
import { execSync } from 'child_process';

export interface ABGatewayStackProps extends cdk.StackProps {
    appName: string;
    controlRuntimeArn: string;
    refinedRuntimeArn: string;
    controlEvalArn: string;
    treatmentEvalArn: string;
}

/**
 * ILocalBundling implementation that runs the create_ab_test.py script
 * locally during CDK synthesis/deployment.
 */
class LocalPythonExecutor implements cdk.ILocalBundling {
    private readonly env: Record<string, string>;

    constructor(env: Record<string, string>) {
        this.env = env;
    }

    tryBundle(outputDir: string, _options: cdk.BundlingOptions): boolean {
        try {
            const scriptPath = path.join(__dirname, '../../scripts/create_ab_test.py');
            const envVars = { ...process.env, ...this.env, OUTPUT_DIR: outputDir };

            console.log('Executing create_ab_test.py locally...');
            execSync(`python "${scriptPath}"`, {
                env: envVars as NodeJS.ProcessEnv,
                stdio: 'inherit',
            });

            return true;
        } catch (e) {
            console.error(`Local Python execution failed: ${e}`);
            return false;
        }
    }
}

export class ABGatewayStack extends cdk.Stack {
    constructor(scope: Construct, id: string, props: ABGatewayStackProps) {
        super(scope, id, props);

        const region = process.env.CDK_DEFAULT_REGION || process.env.AWS_REGION || 'us-east-1';

        // The Asset construct triggers ILocalBundling during synthesis.
        // The Python script creates the gateway, targets, and A/B test via boto3.
        new s3_assets.Asset(this, 'ABTestSetup', {
            path: path.join(__dirname, '../../scripts'),
            bundling: {
                image: cdk.DockerImage.fromRegistry('public.ecr.aws/sam/build-python3.12:latest'),
                local: new LocalPythonExecutor({
                    AWS_REGION: region,
                    APP_NAME: props.appName,
                    CONTROL_RUNTIME_ARN: props.controlRuntimeArn,
                    REFINED_RUNTIME_ARN: props.refinedRuntimeArn,
                    CONTROL_EVAL_ARN: props.controlEvalArn,
                    TREATMENT_EVAL_ARN: props.treatmentEvalArn,
                }),
            },
        });
    }
}
