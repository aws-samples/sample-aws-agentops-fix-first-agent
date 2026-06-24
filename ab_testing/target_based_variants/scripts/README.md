# Scripts

This directory contains all automation scripts for the A/B testing workshop. Scripts are provided in both **bash** (Linux/macOS) and **batch** (Windows) versions where applicable. Python scripts work on all platforms.

## Overview

The scripts support two workflows:

1. **Notebook workflow** — the Jupyter notebook calls these scripts automatically
2. **Standalone workflow** — run scripts directly from the command line without the notebook

### Execution Order

```
1. check_prerequisites.sh/.bat     — verify tools and credentials
2. package_agents.sh/.bat           — bundle agent code for deployment
3. deploy_agents.sh/.bat            — deploy runtimes + eval configs (CDK)
4. deploy_testing_infra.sh/.bat     — deploy gateway + A/B test (CDK + ILocalBundling)
5. send_traffic.sh/.bat/.py         — send prompts through the gateway
6. cleanup_ab_test.py               — tear down gateway, targets, A/B test
7. cleanup_all.sh/.bat              — full teardown (step 6 + CDK destroy)
```

Or use the all-in-one scripts:
```
deploy_all.sh/.bat                  — runs steps 1-4 in sequence
cleanup_all.sh/.bat                 — runs steps 6-7 in sequence
```

---

## Script Reference

### check_prerequisites.sh / check_prerequisites.bat

**Purpose:** Verify that all required tools, credentials, and services are available before starting the workshop.

**What it checks:**
- Python 3.12+ installed
- `uv` package manager installed (auto-installs via pip if missing)
- Node.js installed (required for CDK CLI)
- AWS CLI installed and configured
- AWS credentials valid (not expired)
- CDK bootstrapped (auto-runs `npx cdk bootstrap` if missing)
- Bedrock model access enabled for `amazon.nova-lite-v1:0` and `anthropic.claude-sonnet-4-5-20250929-v1:0`
- Python packages `requests` and `boto3` installed (auto-installs if missing)

**Exit code:** 0 = all OK, 1 = manual action required

**Usage:**
```bash
# Linux/macOS
bash scripts/check_prerequisites.sh

# Windows
scripts\check_prerequisites.bat
```

---

### package_agents.sh / package_agents.bat

**Purpose:** Package both agent variants (control + treatment) into zip-ready `build/` directories for AgentCore Runtime deployment.

**What it does:**
1. Cleans any existing `build/` directory
2. Installs Python dependencies targeting `aarch64-manylinux2014` (Linux arm64) using `uv pip install`
3. Copies agent source code from `src/` into `build/` (includes `bin/opentelemetry-instrument`)
4. Removes Windows `.exe` wrappers that `uv` generates in `bin/` (AgentCore runs Linux)

**Why arm64?** AgentCore Runtime only supports the arm64 instruction set architecture. The `--python-platform aarch64-manylinux2014` flag ensures native `.so` files are compiled for the correct architecture.

**Why the `bin/opentelemetry-instrument` script?** On Linux, pip generates a shell script entry point. On Windows, it generates `.exe` files. Since we package on Windows but deploy to Linux, we include a pre-written Python script that serves as the Linux entry point for OpenTelemetry auto-instrumentation.

**Usage:**
```bash
# Linux/macOS
bash scripts/package_agents.sh ./agents

# Windows
scripts\package_agents.bat agents
```

**Input:** Path to the `agents/` directory containing `control/` and `treatment/` subdirectories.

**Output:** `agents/control/build/` and `agents/treatment/build/` directories ready for CDK deployment.

---

### deploy_agents.sh / deploy_agents.bat

**Purpose:** Deploy both agent runtimes and evaluation configs to AWS via a single CDK stack (`fixFirstAgent-ABTestingStack`).

**What it creates:**
- Two AgentCore Runtimes with zip artifacts from S3
- Two Online Evaluation Configs (Builtin.Helpfulness, 100% sampling)
- IAM roles for runtimes, evaluator, and gateway
- SSM parameters for all resource ARNs

**Prerequisites:**
- Agents must be packaged first (`package_agents.sh/.bat`)
- CDK dependencies installed (`npm install` in the CDK directory)

**Usage:**
```bash
# Linux/macOS
bash scripts/deploy_agents.sh .

# Windows
scripts\deploy_agents.bat .
```

**Input:** Path to the `cdk_ab_testing/` directory.

---

### deploy_testing_infra.sh / deploy_testing_infra.bat

**Purpose:** Deploy the A/B testing gateway infrastructure (gateway, targets, A/B test) via CDK with `ILocalBundling`.

**What it does:**
1. Reads runtime ARNs and eval ARNs from SSM (set by `deploy_agents`)
2. Deploys `fixFirstAgent-ABGatewayStack` passing all ARNs as CDK context
3. During CDK synthesis, `ILocalBundling` triggers `create_ab_test.py` which creates the gateway infrastructure via boto3
4. Prints the gateway URL and A/B test ID

**Prerequisites:**
- `fixFirstAgent-ABTestingStack` must be deployed first (run `deploy_agents.sh/.bat`)

**Usage:**
```bash
# Linux/macOS
bash scripts/deploy_testing_infra.sh .

# Windows
scripts\deploy_testing_infra.bat .
```

**Environment variables (optional):**
- `APP_NAME` — SSM parameter prefix (default: `fixFirstAgent`)
- `AWS_REGION` — AWS region (default: `us-east-1`)

---

### create_ab_test.py

**Purpose:** Create the AgentCore Gateway, HTTP targets, and A/B test via boto3 API calls. Executed automatically by CDK's `ILocalBundling` during `cdk synth`/`cdk deploy`.

**Why Python (not shell)?** These resources require the boto3 SDK (`bedrock-agentcore-control` and `bedrock-agentcore` service clients). The AWS CLI doesn't fully support HTTP gateway targets.

**Why ILocalBundling (not CloudFormation)?** CDK's CloudFormation types don't yet include HTTP gateway targets or A/B test resources. This script bridges the gap by using boto3 directly.

**What it does:**
1. **Cleans up existing resources** — finds any gateway with the same name, stops/deletes its A/B tests, deletes targets, deletes the gateway (all gracefully)
2. **Creates IAM role** — for the gateway to invoke runtimes and read logs (reuses if exists)
3. **Creates gateway** — HTTP protocol, IAM auth, waits for READY status
4. **Creates targets** — `control` and `treatment` pointing to the respective runtime ARNs
5. **Creates A/B test** — 50/50 split, `perVariantOnlineEvaluationConfig`, `enableOnCreate=True`
6. **Stores results in SSM** — gateway ID, gateway ARN, gateway URL, A/B test ID

**Environment variables (set by CDK):**
| Variable | Description |
|----------|-------------|
| `AWS_REGION` | AWS region |
| `APP_NAME` | SSM parameter prefix |
| `CONTROL_RUNTIME_ARN` | Control agent runtime ARN |
| `REFINED_RUNTIME_ARN` | Treatment agent runtime ARN |
| `CONTROL_EVAL_ARN` | Control online evaluation config ARN |
| `TREATMENT_EVAL_ARN` | Treatment online evaluation config ARN |
| `OUTPUT_DIR` | Directory for CDK asset output (set automatically) |

**Idempotency:** The script always tears down existing resources and creates fresh ones, ensuring a consistent state on every run.

**SSM parameters written:**
| Parameter | Value |
|-----------|-------|
| `/{APP_NAME}/ab-gateway-id` | Gateway identifier |
| `/{APP_NAME}/ab-gateway-arn` | Gateway ARN |
| `/{APP_NAME}/ab-gateway-url` | Gateway HTTPS endpoint URL |
| `/{APP_NAME}/ab-test-id` | A/B test identifier |

---

### cleanup_ab_test.py

**Purpose:** Delete all gateway infrastructure created by `create_ab_test.py`. Called from the notebook's cleanup cell before `cdk destroy`.

**Why a separate script?** CDK's `ILocalBundling` runs at synth time (before CloudFormation operations), so it can't distinguish `cdk deploy` from `cdk destroy`. Cleanup must be a separate, explicit step.

**What it does (in order):**
1. Reads gateway ID and A/B test ID from SSM
2. Stops the A/B test (`executionStatus='STOPPED'`), waits 15s, then deletes it
3. Deletes gateway targets (`control`, `treatment`), waits 10s
4. Deletes the gateway
5. Deletes the IAM role and its inline policy
6. Removes SSM parameters (`ab-gateway-id`, `ab-gateway-arn`, `ab-gateway-url`, `ab-test-id`)

**Graceful failure:** Every step is wrapped in try/except. If a resource doesn't exist or is already deleted, the script logs the error and continues.

**Environment variables:**
| Variable | Description |
|----------|-------------|
| `AWS_REGION` | AWS region (default: `us-east-1`) |
| `APP_NAME` | SSM parameter prefix (default: `fixFirstAgent`) |

**Usage:**
```bash
python scripts/cleanup_ab_test.py
```

---

### send_traffic.sh / send_traffic.bat / send_traffic.py

**Purpose:** Send prompts through the AgentCore Gateway for A/B testing. Each request gets a unique session ID and is routed to control or treatment by the A/B test.

**Why SigV4?** The AgentCore Gateway is a raw HTTPS endpoint that requires AWS SigV4 request signing. There is no `aws` CLI command for gateway invocation.

**Platform handling:**
- **Linux/macOS** (`send_traffic.sh`): Uses `curl --aws-sigv4` (native since curl 7.75)
- **Windows** (`send_traffic.bat`): Calls `send_traffic.py` which uses Python `botocore` for SigV4 signing (curl's `--aws-sigv4` quoting is unreliable on cmd.exe)
- **Cross-platform** (`send_traffic.py`): Python implementation, works everywhere

**Usage:**
```bash
# Linux/macOS
bash scripts/send_traffic.sh https://gateway-url us-east-1 prompts.txt

# Windows
scripts\send_traffic.bat https://gateway-url us-east-1 prompts.txt

# Direct Python (any platform)
python scripts/send_traffic.py https://gateway-url us-east-1 prompts.txt
```

**Arguments:**
1. Gateway URL (from SSM: `/{APP_NAME}/ab-gateway-url`)
2. AWS region (default: `us-east-1`)
3. Prompts file path (default: `prompts.txt`)

---

### deploy_all.sh / deploy_all.bat

**Purpose:** Run the complete deployment pipeline end-to-end (package + deploy runtimes + deploy gateway).

**What it does:**
1. Packages both agents (`package_agents`)
2. Deploys runtimes + eval configs (`deploy_agents`)
3. Deploys gateway + A/B test (`deploy_testing_infra`)

**Usage:**
```bash
# Linux/macOS
bash scripts/deploy_all.sh

# Windows
scripts\deploy_all.bat
```

---

### cleanup_all.sh / cleanup_all.bat

**Purpose:** Complete teardown of all A/B testing infrastructure.

**What it does:**
1. Runs `cleanup_ab_test.py` (stops/deletes A/B test, gateway, targets, IAM role, SSM params)
2. Destroys `fixFirstAgent-ABGatewayStack` (CDK)
3. Destroys `fixFirstAgent-ABTestingStack` (CDK)

**Usage:**
```bash
# Linux/macOS
bash scripts/cleanup_all.sh

# Windows
scripts\cleanup_all.bat
```

---

```
┌─────────────────────────────────────────────────────────────┐
│                    CDK Stack 1                                │
│              fixFirstAgent-ABTestingStack                     │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │ Control      │  │ Treatment    │  │ Online Eval       │  │
│  │ Runtime      │  │ Runtime      │  │ Configs (x2)      │  │
│  │ (Nova Lite)  │  │ (Claude 4.5) │  │ Builtin.Helpful.  │  │
│  └──────────────┘  └──────────────┘  └──────────────────┘  │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                    CDK Stack 2                                │
│              fixFirstAgent-ABGatewayStack                     │
│              (ILocalBundling → create_ab_test.py)             │
│                                                              │
│  ┌──────────────┐  ┌─────────┐  ┌─────────┐  ┌──────────┐ │
│  │ Gateway      │  │ Target: │  │ Target: │  │ A/B Test │ │
│  │ (IAM auth)   │  │ control │  │ treat.  │  │ 50/50    │ │
│  └──────────────┘  └─────────┘  └─────────┘  └──────────┘ │
└─────────────────────────────────────────────────────────────┘

Traffic flow (request path):
  Client → Gateway → [injects baggage header with experiment ARN + variant name]
                   → A/B routing (50/50) → Target → AgentCore Runtime
                                                          ↓
                                               Response back to Client

Observability flow (async, after session completes):
  AgentCore Runtime → OTel spans (stamped with experiment ARN + variant)
                    → CloudWatch Logs (log group per runtime endpoint)
                              ↓
                    Online Evaluator reads completed sessions from CloudWatch
                              ↓
                    LLM judge (Builtin.Helpfulness) scores each session
                              ↓
                    Scores written to evaluation results log group
                              ↓
                    A/B test aggregation pipeline reads scores
                              ↓
                    Computes per-variant: mean, sample size, p-value, CI
                              ↓
                    Results available via GetABTest API
```

---

## Standalone Usage (without notebook)

```bash
# 1. Check prerequisites
bash scripts/check_prerequisites.sh

# 2. Deploy everything (package + runtimes + eval + gateway + A/B test)
bash scripts/deploy_all.sh

# 3. Send traffic
bash scripts/send_traffic.sh $(aws ssm get-parameter --name /fixFirstAgent/ab-gateway-url --query Parameter.Value --output text) us-east-1 prompts.txt

# 4. Check results (wait ~15 min)
aws bedrock-agentcore get-ab-test --ab-test-id $(aws ssm get-parameter --name /fixFirstAgent/ab-test-id --query Parameter.Value --output text)

# 5. Full cleanup
bash scripts/cleanup_all.sh
```
