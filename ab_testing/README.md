# A/B Testing with Amazon Bedrock AgentCore

This workshop demonstrates two patterns for running **A/B tests** using Amazon Bedrock AgentCore. You split live traffic between agent variants via the AgentCore Gateway and use automated online evaluation to determine which performs better with statistical significance.

| Lab | Pattern | What varies | Infra |
|-----|---------|-------------|-------|
| **Lab 1** | Target-based | Two separate runtimes (different models/prompts) | 2 runtimes, 2 targets |
| **Lab 2** | Configuration-based | Single runtime, config bundles swap the prompt | 1 runtime, 1 target, 2 config bundles |

## Architecture — Lab 1: Target-Based

```
┌─────────────────────────────────────────────────────────────────┐
│                  AgentCore Gateway (IAM Auth)                   │
│                                                                 │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │            A/B Test (50/50 traffic split)               │   │
│   │     Assigns session → variant (sticky routing)          │   │
│   └────────────────────────┬────────────────────────────────┘   │
└────────────────────────────┼────────────────────────────────────┘
                             │
              ┌──────────────┴──────────────┐
              │                             │
    ┌─────────┴─────────┐        ┌──────────┴──────────┐
    │  Target: control  │        │  Target: treatment  │
    └─────────┬─────────┘        └──────────┬──────────┘
              │                             │
    ┌─────────┴─────────┐        ┌──────────┴──────────┐
    │  AgentCore Runtime│        │  AgentCore Runtime  │
    │  Amazon Nova Lite │        │  Claude Sonnet 4.5  │
    │  (Control - C)    │        │  (Treatment - T1)   │
    └─────────┬─────────┘        └──────────┬──────────┘
              │                             │
         OTel spans                    OTel spans
              │                             │
    ┌─────────┴─────────┐        ┌──────────┴──────────┐
    │  Online Eval (C)  │        │  Online Eval (T1)   │
    │  Builtin.         │        │  Builtin.           │
    │  Helpfulness      │        │  Helpfulness        │
    └─────────┬─────────┘        └──────────┬──────────┘
              │                             │
              └─────────────┬───────────────┘
                            │
              ┌─────────────┴───────────────┐
              │   A/B Test Aggregation      │
              │   mean, p-value, CI,        │
              │   significance,             │
              │   recommendation            │
              └─────────────────────────────┘
```

## Architecture — Lab 2: Configuration-Based

```
┌─────────────────────────────────────────────────────────────────┐
│                  AgentCore Gateway (IAM Auth)                   │
│                                                                 │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │            A/B Test (50/50 traffic split)               │   │
│   │  Variant C  → configBundle: control-bundle v1          │   │
│   │  Variant T1 → configBundle: treatment-bundle v1        │   │
│   └────────────────────────┬────────────────────────────────┘   │
└────────────────────────────┼────────────────────────────────────┘
                             │
                  ┌──────────┴──────────┐
                  │  Target: fixfirst   │
                  └──────────┬──────────┘
                             │
                  ┌──────────┴──────────┐
                  │  AgentCore Runtime  │
                  │  (single agent)     │
                  │  reads config bundle│
                  │  at invocation time │
                  └──────────┬──────────┘
                             │
                        OTel spans
                             │
                  ┌──────────┴──────────┐
                  │  Online Evaluation  │
                  │  Builtin.Helpfulness│
                  └──────────┬──────────┘
                             │
              ┌──────────────┴──────────────┐
              │   A/B Test Aggregation      │
              │   mean, p-value, CI,        │
              │   significance,             │
              │   recommendation            │
              └─────────────────────────────┘
```

## How It Works

1. **Client sends request** → Gateway receives it with SigV4 auth
2. **A/B test assigns variant** → based on session ID (sticky: same session always goes to same variant)
3. **Gateway routes to target** → In Lab 1, routes to one of two runtimes; in Lab 2, routes to a single runtime with a config bundle attached
4. **Runtime processes request** → generates OTel spans with baggage headers (experiment ARN + variant name)
5. **Session completes** → after 15 min idle timeout
6. **Online evaluator scores session** → `Builtin.Helpfulness` LLM judge rates each response
7. **Aggregation computes statistics** → mean scores, p-value, confidence interval, significance flag
8. **Recommendation** → deploy winner or continue collecting data

## Use Case: FixFirst Appliance Support Agent

### Lab 1 — Target-Based (different models)

| | Control (C) | Treatment (T1) |
|---|---|---|
| **Model** | Amazon Nova Lite | Claude Sonnet 4.5 |
| **Prompt style** | Conversational, one question at a time | Structured IDENTIFY/DIAGNOSE/RESOLVE |
| **Cost** | Lower | Higher |
| **Hypothesis** | Friendly but may lack depth | Structured approach = more helpful |

### Lab 2 — Configuration-Based (same model, different prompts)

| | Control (C) | Treatment (T1) |
|---|---|---|
| **Model** | Claude Sonnet 4.5 | Claude Sonnet 4.5 |
| **Prompt** | Conversational (default) | Structured IDENTIFY/DIAGNOSE/RESOLVE |
| **Runtime** | Single shared runtime | Single shared runtime |
| **Hypothesis** | Same model, better prompt = more helpful |

**Expected outcome:** Treatment scores higher on helpfulness. If statistically significant (p < 0.05), we have data to justify the change in production.

## Quick Start

**Lab 1 — Target-Based (notebook):**
```bash
cd ab_testing
jupyter notebook lab1_ab_testing_targets.ipynb
```

**Lab 2 — Configuration-Based (notebook):**
```bash
cd ab_testing
jupyter notebook lab2_ab_testing_config_bundle.ipynb
```

**End-to-end scripts (no notebook):**
```bash
./run_target_ab_testing.sh        # Lab 1
./run_config_ab_testing.sh        # Lab 2
```

## Project Structure

```
ab_testing/
├── lab1_ab_testing_targets.ipynb       # Lab 1 notebook (Bash kernel, Linux/macOS)
├── lab2_ab_testing_config_bundle.ipynb  # Lab 2 notebook (Bash kernel, Linux/macOS)
├── run_target_ab_testing.sh            # Lab 1 end-to-end script
├── run_config_ab_testing.sh            # Lab 2 end-to-end script
├── prompts.txt                         # 20 appliance troubleshooting prompts
├── README.md
├── scripts/                            # Shared scripts (both labs)
│   ├── check_prerequisites.sh
│   ├── check_ab_results.py             # Pretty-prints A/B test results
│   ├── send_traffic.sh
│   └── send_traffic.py                 # SigV4 signing for gateway requests
├── target_based_variants/              # Lab 1: two runtimes, two targets
│   ├── agents/
│   │   ├── control/                    # Nova Lite agent
│   │   └── treatment/                  # Claude Sonnet 4.5 agent
│   ├── cdk_ab_testing/                 # CDK: runtimes + eval configs
│   ├── cdk_ab_gateway/                 # CDK: gateway + targets + A/B test
│   └── scripts/
│       ├── package_agents.sh
│       ├── deploy_agents.sh
│       ├── deploy_all.sh
│       ├── deploy_testing_infra.sh
│       ├── create_ab_test.py
│       ├── cleanup_ab_test.py
│       └── cleanup_all.sh
├── configuration_based_variants/       # Lab 2: single runtime, config bundles
│   ├── agent/src/main.py              # Agent with BeforeModelCallEvent hook
│   ├── cdk/                            # CDK: one runtime + shared eval config
│   └── scripts/
│       ├── package_config_agent.sh
│       ├── deploy_config_agent.sh
│       ├── create_config_ab_test.py    # Creates bundles + gateway + A/B test
│       ├── cleanup_config_ab_test.py
│       └── cleanup_config_all.sh
└── win/                                # Windows notebooks + .bat scripts
```

## Interpreting Results

| Metric | Meaning |
|--------|---------|
| `mean` | Average helpfulness score (0-1) for the variant |
| `sampleSize` | Number of sessions evaluated |
| `percentChange` | % improvement of treatment over control |
| `pValue` | Probability the difference is due to chance |
| `isSignificant` | `true` if p < 0.05 |
| `confidenceInterval` | 95% range where the true difference lies |

**Decision rules:**
- `isSignificant: true` + positive `percentChange` → **Deploy treatment**
- `isSignificant: true` + negative `percentChange` → **Keep control**
- `isSignificant: false` → **Continue collecting data** (need more samples)

## Documentation

- [A/B Testing Overview](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/ab-testing.html)
- [Target-Based A/B Testing Guide](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/ab-testing-target-based.html)
- [Configuration Bundle A/B Testing](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/ab-testing-config-bundle.html)
- [A/B Testing Prerequisites](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/ab-testing-prereqs.html)
- [Managing A/B Tests](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/ab-testing-manage.html)
- [AgentCore Gateway Concepts](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway-core-concepts.html)
- [Gateway HTTP Runtime Targets](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway-target-http-runtime.html)
- [Online Evaluation](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/create-online-evaluations.html)
- [Evaluation Results & Output](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/results-and-output.html)
- [Observability & OpenTelemetry](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/observability-get-started.html)
- [AgentCore Optimization](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/optimization.html)

## Prerequisites

- Python 3.12+
- `uv` (Python package installer)
- Node.js (for CDK)
- AWS CLI >= 2.34
- CDK bootstrapped (`npx cdk bootstrap`)
- Bedrock model access: `amazon.nova-lite-v1:0` and `anthropic.claude-sonnet-4-5-20250929-v1:0`

### SageMaker Execution Role Permissions

The SageMaker execution role must have access to the following services:

- `cloudformation:*`
- `s3:*`
- `iam:*`
- `ssm:*`
- `ecr:*`
- `bedrock:*`
- `bedrock-agentcore:*`
- `bedrock-agentcore-control:*`
- `logs:*`
- `sts:*`

For workshop/burner accounts, attaching `AdministratorAccess` to the SageMaker execution role is the simplest approach.

### SageMaker JupyterLab Setup

The lab notebooks require a **Bash kernel**. Before opening any notebook, run the following in the JupyterLab terminal:

```bash
pip install bash_kernel
python -m bash_kernel.install --sys-prefix
```

Then close and reopen the notebook. When prompted, select **Bash** as the kernel.
