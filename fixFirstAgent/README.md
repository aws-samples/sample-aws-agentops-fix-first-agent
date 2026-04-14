# FixFirst Agent — Runtime

The agent runtime code and CDK infrastructure for the FixFirst appliance troubleshooting agent.

## Directory Layout

### src/

Runtime code for the Bedrock AgentCore agent.

- `main.py` — AgentCore entrypoint. Defines the Strands agent with a system prompt, memory hooks, and session management.
- `model/load.py` — Bedrock model configuration (currently Amazon Nova 2 Lite).
- `long_term_memory_hook.py` — Hook provider that retrieves customer context before each query and saves interactions after each response.

### mcp/

Lambda-backed MCP tool behind the AgentCore Gateway.

- `lambda/handler.py` — Placeholder tool demonstrating the Gateway tool naming convention. When replacing with a real tool, update both the handler and the inline tool schema in the CDK stack.

### cdk/

CDK project that provisions all AWS resources:

- Bedrock AgentCore Runtime (zip-based, Python 3.12)
- Bedrock AgentCore Gateway + Lambda target
- Bedrock AgentCore Memory (semantic, summary, user preference strategies)
- Cognito User Pool + App Client
- SSM Parameters for cross-stack configuration
- Runtime IAM roles and policies

## Deployment

The agent is deployed as part of the full platform via `scripts/deploy-all.sh` from the repo root. To deploy just the agent stack:

```bash
# Package dependencies first
bash scripts/package-agent.sh

# Deploy
cd cdk
npm install
npx cdk deploy fixFirstAgent-AgentCoreStack --require-approval never
```

## Invoking

```bash
agentcore invoke '{"prompt": "My washing machine won't drain"}'
```

Or use the Bedrock AgentCore console Test Console with the `DEFAULT` qualifier.
