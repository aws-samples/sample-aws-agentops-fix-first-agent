# FixFirst Agent — Multi-Region Active-Passive Deployment

This module adds multi-region resilience to the FixFirst Agent using an **active-passive failover** pattern with operator-controlled DNS switching.

## Architecture

```
                    ┌──────────────────────────────────────────────┐
                    │         Route 53 (Failover Routing)          │
                    │     api.fixfirst.<your-domain>               │
                    │  Primary: us-east-1 | Secondary: us-west-2   │
                    └──────────┬─────────────────────┬─────────────┘
                               │                     │
              ┌────────────────▼────────┐  ┌────────▼─────────────────┐
              │  API Gateway (Regional) │  │  API Gateway (Regional)  │
              │  us-east-1              │  │  us-west-2               │
              └────────────┬────────────┘  └────────┬─────────────────┘
                           │                        │
              ┌────────────▼────────────┐  ┌────────▼─────────────────┐
              │  Lambda Proxy           │  │  Lambda Proxy            │
              │  → InvokeAgentRuntime   │  │  → InvokeAgentRuntime   │
              └────────────┬────────────┘  └────────┬─────────────────┘
                           │                        │
              ┌────────────▼────────────┐  ┌────────▼─────────────────┐
              │  AgentCore Runtime       │  │  AgentCore Runtime       │
              │  (existing stack)        │  │  (existing stack)        │
              └─────────────────────────┘  └──────────────────────────┘
```

## Stacks

| Stack | Region | Purpose |
|-------|--------|---------|
| `PrerequisitesStack` | Each region | Route 53 hosted zone + ACM certificate (DNS validated) |
| `RegionalProxyStack` | Each region | API Gateway + Lambda proxy forwarding to local AgentCore Runtime |
| `RoutingStack` | Primary region | Route 53 failover records + CloudWatch alarm health check |

## Prerequisites

1. **FixFirst Agent deployed in both regions** — Run the existing `fixFirstAgent` CDK deploy in both `us-east-1` and `us-west-2`.
2. **A domain name you own** — e.g., `fixfirst.example.com` (registered anywhere: Route 53, GoDaddy, Namecheap, etc.)

## Configuration

Edit `cdk/bin/app.ts` and replace the placeholder values:

```typescript
// Replace these:
const domainName = 'api.fixfirst.example.com';       // Your API subdomain
const hostedZoneName = 'fixfirst.example.com';       // Your base domain
const primaryAgentRuntimeArn = 'arn:aws:bedrock-agentcore:us-east-1:ACCOUNT:runtime/ID';
const secondaryAgentRuntimeArn = 'arn:aws:bedrock-agentcore:us-west-2:ACCOUNT:runtime/ID';
const cognitoUserPoolId = 'us-east-1_XXXXXXXXX';
```

Or pass them as context arguments to the deploy script (see below).

## Deployment

### Full deployment (all phases)

```bash
cd fixFirstAgent-multi-region

./scripts/deploy.sh \
  --domain api.fixfirst.example.com \
  --hosted-zone-name fixfirst.example.com \
  --primary-region us-east-1 \
  --secondary-region us-west-2 \
  --primary-runtime-arn arn:aws:bedrock-agentcore:us-east-1:123456789012:runtime/abc123 \
  --secondary-runtime-arn arn:aws:bedrock-agentcore:us-west-2:123456789012:runtime/def456 \
  --cognito-pool-id us-east-1_XXXXXXXXX
```

### Phase-by-phase deployment

You can deploy one phase at a time using `--phase`:

```bash
# Phase 0: Create hosted zone + certificates
./scripts/deploy.sh --phase 0 ...

# ⚠️  ACTION REQUIRED: Update NS records at your domain registrar!
# Wait for ACM certificates to become ISSUED.

# Phase 1: Deploy API Gateway + Lambda proxy in both regions
./scripts/deploy.sh --phase 1 ...

# Phase 2: Deploy Route 53 failover routing
./scripts/deploy.sh --phase 2 ...
```

### If you already have a hosted zone

```bash
./scripts/deploy.sh \
  --existing-hosted-zone-id Z0123456789ABC \
  --domain api.fixfirst.example.com \
  ...
```

## After Phase 0: NS Record Setup

If a new hosted zone was created, the stack output will show name servers like:

```
NameServers: ns-123.awsdns-45.com, ns-678.awsdns-90.net, ns-111.awsdns-22.org, ns-333.awsdns-44.co.uk
```

Add these as NS records at your domain registrar for your hosted zone name (e.g., `fixfirst.example.com`). ACM certificates will not validate until DNS resolves correctly.

## Failover Operations

### Trigger failover to secondary region

```bash
./scripts/failover.sh trigger --region us-east-1
```

### Return to primary region

```bash
./scripts/failover.sh restore --region us-east-1
```

### Check current status

```bash
./scripts/failover.sh status --region us-east-1
```

### How it works

The failover mechanism uses a CloudWatch custom metric:
- **Metric namespace:** `FixFirstAgent/HealthCheck`
- **Metric name:** `Failover`
- **Alarm threshold:** value >= 1 triggers failover

When the alarm enters ALARM state, the Route 53 health check fails, and DNS automatically routes traffic to the secondary region's API Gateway.

## Client Changes

Update your web frontend to call the custom domain instead of the direct AgentCore endpoint:

```javascript
// Before (single region, direct to AgentCore):
const url = `https://bedrock-agentcore.${region}.amazonaws.com/runtimes/${arn}/invocations`;

// After (multi-region via custom domain):
const url = `https://api.fixfirst.example.com/invoke`;
```

The request body and headers remain the same — the Lambda proxy forwards them to the local region's AgentCore Runtime.

## Limitations

- **Memory/sessions do not replicate** across regions. On failover, users start new sessions.
- **Cognito stays in one region** — both regions validate tokens from the same user pool via OIDC discovery.
- **Failover is operator-controlled** via CloudWatch metric (can be automated with alarms on AgentCore error rates or latency).
- **DNS TTL** — failover takes effect within ~60 seconds depending on client DNS caching.

## Cost Considerations

- API Gateway: Pay per request (minimal cost for the proxy layer)
- Lambda: Pay per invocation + duration (120s timeout, 256MB)
- Route 53: $0.50/hosted zone/month + $0.75/health check/month
- ACM: Free (certificates are free when used with AWS services)
- CloudWatch: Minimal (1 custom metric + 1 alarm)
