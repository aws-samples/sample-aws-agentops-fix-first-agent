#!/bin/bash
# Deploy the configuration-based agent runtime via CDK.
# Usage: ./deploy_config_agent.sh [cdk_dir]

set -euo pipefail

CDK_DIR="$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/../cdk}" && pwd)"

echo "Deploying config-based agent runtime..."
cd "$CDK_DIR"

if [ ! -d "node_modules" ]; then
    echo "Installing CDK dependencies..."
    npm install
fi

npx cdk deploy fixFirstAgent-ConfigABTestingStack --require-approval never

echo "Config-based agent runtime deployed."
