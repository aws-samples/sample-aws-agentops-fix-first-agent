# FixFirst Agent

An AI-powered appliance troubleshooting agent built on AWS Bedrock AgentCore. Customers describe their appliance issue and the agent guides them step-by-step through diagnosis and repair.

## Architecture

- **Agent Runtime** — Python (Strands SDK) running on Bedrock AgentCore Runtime
- **Memory** — Bedrock AgentCore Memory for cross-session context (semantic, summary, user preferences)
- **Auth** — Amazon Cognito (user pool with email verification)
- **Frontend** — Static SPA hosted on S3 + CloudFront
- **MCP Gateway** — Bedrock AgentCore Gateway with Lambda-backed placeholder tool
- **Infrastructure** — AWS CDK (TypeScript), two stacks: AgentCoreStack + WebHostingStack

## Project Structure

```
├── fixFirstAgent/              # Agent runtime + CDK infrastructure
│   ├── src/                    # Python agent source code
│   │   ├── main.py             # AgentCore entrypoint
│   │   ├── model/load.py       # Bedrock model configuration
│   │   └── long_term_memory_hook.py  # Memory retrieval/save hooks
│   ├── mcp/lambda/             # MCP Gateway Lambda handler
│   ├── cdk/                    # CDK stack (AgentCore, Cognito, Gateway, Memory)
│   └── requirements.txt        # Python runtime dependencies
├── fixFirstAgentWeb/static/    # Static SPA frontend
│   ├── index.html              # Chat interface
│   ├── login.html / register.html  # Auth pages
│   ├── auth.js                 # Cognito auth module
│   ├── agent.js                # AgentCore invocation module
│   └── styles.css              # Shared styles
├── cdk/                        # CDK stack (S3 + CloudFront web hosting)
└── scripts/                    # Deployment scripts
    ├── deploy-all.sh           # Full end-to-end deployment
    ├── deploy-web.sh           # Web-only redeployment
    ├── package-agent.sh        # Package Python agent for AgentCore
    └── generate-config.sh      # Generate frontend config from SSM
```

## Prerequisites

- Node.js >= 18
- Python >= 3.10
- [uv](https://docs.astral.sh/uv/getting-started/installation/) (Python package manager)
- AWS CLI v2 configured with credentials
- CDK bootstrapped in target account/region (`cdk bootstrap`)

## Deployment

From a bash shell (Git Bash or WSL on Windows):

```bash
bash scripts/deploy-all.sh
```

This runs 6 steps: package agent → deploy AgentCore stack → generate config.js → deploy web hosting stack → retrieve CloudFront URL → redeploy AgentCore with CloudFront callback URLs.

## Local Development

The agent can be invoked directly via the AgentCore CLI:

```bash
agentcore invoke '{"prompt": "My refrigerator is making a buzzing noise"}'
```

Or use the Bedrock AgentCore console Test Console with the `DEFAULT` qualifier.
