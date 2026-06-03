#!/bin/bash
# Check prerequisites for the A/B testing workshop.
# Verifies all required tools, credentials, and services are available.
# Auto-fixes what it can (uv, CDK bootstrap, pip packages).
# Exit code: 0 if all prerequisites are met, 1 otherwise.

set -o pipefail

ALL_OK=true

echo "Checking prerequisites..."
echo "============================================================"

# Python 3.12+
PY_VER=$(python3 --version 2>/dev/null | awk '{print $2}')
if [ -z "$PY_VER" ]; then
    PY_VER=$(python --version 2>/dev/null | awk '{print $2}')
fi
PY_MAJOR=$(echo "$PY_VER" | cut -d. -f1)
PY_MINOR=$(echo "$PY_VER" | cut -d. -f2)
if [ "$PY_MAJOR" -ge 3 ] 2>/dev/null && [ "$PY_MINOR" -ge 12 ] 2>/dev/null; then
    echo "[OK] Python 3.12+: $PY_VER"
else
    echo "[FAIL] Python 3.12+: ${PY_VER:-not found}"
    echo "   ACTION REQUIRED: Install Python 3.12+ from https://www.python.org/downloads/"
    ALL_OK=false
fi

# uv
if uv --version >/dev/null 2>&1; then
    echo "[OK] uv: $(uv --version)"
else
    echo "[FIXING] uv not found, installing..."
    pip install uv >/dev/null 2>&1 || pip3 install uv >/dev/null 2>&1
    if uv --version >/dev/null 2>&1; then
        echo "[OK] uv installed"
    else
        echo "[FAIL] uv installation failed"
        echo "   ACTION REQUIRED: Install from https://docs.astral.sh/uv/getting-started/installation/"
        ALL_OK=false
    fi
fi

# Node.js
if node --version >/dev/null 2>&1; then
    echo "[OK] Node.js: $(node --version)"
else
    echo "[FAIL] Node.js not found"
    echo "   ACTION REQUIRED: Install from https://nodejs.org/"
    ALL_OK=false
fi

# AWS CLI >= 2.34
if aws --version >/dev/null 2>&1; then
    CLI_VER=$(aws --version 2>&1 | awk '{print $1}' | cut -d/ -f2)
    CLI_MAJOR=$(echo "$CLI_VER" | cut -d. -f1)
    CLI_MINOR=$(echo "$CLI_VER" | cut -d. -f2)
    if [ "$CLI_MAJOR" -ge 2 ] 2>/dev/null && [ "$CLI_MINOR" -ge 34 ] 2>/dev/null; then
        echo "[OK] AWS CLI: $CLI_VER"
    else
        echo "[FIXING] AWS CLI $CLI_VER is too old. Need >= 2.34. Updating..."
        curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip \
            && unzip -qo /tmp/awscliv2.zip -d /tmp \
            && sudo /tmp/aws/install --update >/dev/null 2>&1 \
            && rm -rf /tmp/awscliv2.zip /tmp/aws
        CLI_VER=$(aws --version 2>&1 | awk '{print $1}' | cut -d/ -f2)
        CLI_MINOR=$(echo "$CLI_VER" | cut -d. -f2)
        if [ "$CLI_MINOR" -ge 34 ] 2>/dev/null; then
            echo "[OK] AWS CLI updated to $CLI_VER"
        else
            echo "[FAIL] AWS CLI update failed. Current: $CLI_VER"
            echo "   ACTION REQUIRED: Update manually from https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
            ALL_OK=false
        fi
    fi
else
    echo "[FAIL] AWS CLI not found"
    echo "   ACTION REQUIRED: Install from https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    ALL_OK=false
fi

# AWS credentials
IDENTITY=$(aws sts get-caller-identity 2>/dev/null)
if [ $? -eq 0 ]; then
    ARN=$(echo "$IDENTITY" | python3 -c "import sys,json;print(json.load(sys.stdin)['Arn'])" 2>/dev/null || echo "$IDENTITY" | python -c "import sys,json;print(json.load(sys.stdin)['Arn'])" 2>/dev/null)
    echo "[OK] AWS credentials: $ARN"
else
    echo "[FAIL] AWS credentials not configured or expired"
    echo "   ACTION REQUIRED: Run 'aws configure' or 'aws sso login' or export AWS_* env vars"
    ALL_OK=false
fi

# CDK bootstrapped (skip check — SageMaker role typically lacks cloudformation:DescribeStacks)
# If CDK is not bootstrapped in your account/region, run manually: npx cdk bootstrap
echo "[INFO] CDK bootstrap check skipped (verify manually if needed: npx cdk bootstrap)"

# Bedrock model access
MODELS=$(aws bedrock list-foundation-models --by-output-modality TEXT --query 'modelSummaries[].modelId' --output json 2>/dev/null)
if [ $? -eq 0 ]; then
    for MODEL in "amazon.nova-lite-v1:0" "anthropic.claude-sonnet-4-5-20250929-v1:0"; do
        if echo "$MODELS" | grep -q "\"$MODEL\""; then
            echo "[OK] Bedrock model: $MODEL"
        else
            echo "[FAIL] Bedrock model not enabled: $MODEL"
            echo "   ACTION REQUIRED: Enable in Bedrock console -> Model access"
            ALL_OK=false
        fi
    done
else
    echo "[FAIL] Unable to check Bedrock models (check AWS credentials/permissions)"
    ALL_OK=false
fi

# boto3/botocore — must be new enough to know bedrock-agentcore-control service
PYTHON_CMD=$(command -v python3 || command -v python)
BOTO_OK=$("$PYTHON_CMD" -c "import botocore; from botocore.session import Session; Session().create_client('bedrock-agentcore-control', region_name='us-east-1')" 2>/dev/null && echo yes || echo no)
if [ "$BOTO_OK" = "yes" ]; then
    BOTO_VER=$("$PYTHON_CMD" -c "import boto3; print(boto3.__version__)" 2>/dev/null)
    echo "[OK] boto3/botocore: $BOTO_VER (bedrock-agentcore-control supported)"
else
    echo "[FIXING] boto3/botocore too old (missing bedrock-agentcore-control). Upgrading..."
    "$PYTHON_CMD" -m pip install --upgrade boto3 botocore >/dev/null 2>&1
    BOTO_OK=$("$PYTHON_CMD" -c "import botocore; from botocore.session import Session; Session().create_client('bedrock-agentcore-control', region_name='us-east-1')" 2>/dev/null && echo yes || echo no)
    if [ "$BOTO_OK" = "yes" ]; then
        BOTO_VER=$("$PYTHON_CMD" -c "import boto3; print(boto3.__version__)" 2>/dev/null)
        echo "[OK] boto3/botocore upgraded to $BOTO_VER"
    else
        echo "[FAIL] boto3/botocore upgrade failed"
        echo "   ACTION REQUIRED: Run 'pip install --upgrade boto3 botocore'"
        ALL_OK=false
    fi
fi

# pip packages
for PKG in requests; do
    if "$PYTHON_CMD" -c "import $PKG" 2>/dev/null; then
        echo "[OK] $PKG package"
    else
        echo "[FIXING] $PKG package not found, installing..."
        "$PYTHON_CMD" -m pip install "$PKG" >/dev/null 2>&1
        if "$PYTHON_CMD" -c "import $PKG" 2>/dev/null; then
            echo "[OK] $PKG installed"
        else
            echo "[FAIL] $PKG installation failed"
            ALL_OK=false
        fi
    fi
done

echo "============================================================"
if [ "$ALL_OK" = true ]; then
    echo ""
    echo "All prerequisites satisfied! You can proceed."
    exit 0
else
    echo ""
    echo "Some prerequisites need manual action (see items marked FAIL above)."
    exit 1
fi
