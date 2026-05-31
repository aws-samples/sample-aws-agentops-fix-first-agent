#!/bin/bash
# Deploy both agent runtimes and evaluation configs to AgentCore via CDK.
#
# This deploys the fixFirstAgent-ABTestingStack which creates:
#   - Two AgentCore Runtimes (control: Nova Lite, treatment: Claude 4.5)
#   - Two Online Evaluation Configs (Builtin.Helpfulness, 100% sampling)
#   - IAM roles for runtimes, evaluator, and gateway
#   - SSM parameters for all resource ARNs
#
# Prerequisites:
#   - Agents must be packaged first (run package_agents.sh)
#   - CDK dependencies installed (npm install in cdk_dir)
#
# Usage: ./deploy_agents.sh <cdk_dir>

set -euo pipefail

CDK_DIR="${1:-.}"

echo "Deploying agent runtimes and evaluation configs..."
cd "$CDK_DIR"

# Install CDK dependencies if needed
if [ ! -d "node_modules" ]; then
    echo "Installing CDK dependencies..."
    npm install
fi

npx cdk deploy fixFirstAgent-ABTestingStack --require-approval never

echo "Agent runtimes and evaluation configs deployed."
