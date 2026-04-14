# FixFirst Agent Web

Static web application for the FixFirst Agent, deployed to S3 + CloudFront.

## Architecture

- Pure client-side SPA (HTML/CSS/JS) — no server required
- Authenticates directly with Cognito using `USER_PASSWORD_AUTH`
- Calls AgentCore Runtime endpoint with the Cognito bearer token
- Configuration is loaded from `config.js`, generated from SSM Parameter Store

## Local Development

1. Deploy the AgentCore stack first (`fixFirstAgent/cdk`).
2. Generate the config:
   ```bash
   bash scripts/generate-config.sh
   ```
3. Serve the static files locally:
   ```bash
   python3 -m http.server 8080 -d fixFirstAgentWeb/static
   ```
4. Open `http://localhost:8080/login.html`

## Deployment

### Prerequisites
- AgentCore stack deployed (`fixFirstAgent/cdk`)
- AWS CLI configured with appropriate permissions

### Full Deploy
```bash
bash scripts/deploy-web.sh
```

This script:
1. Reads SSM parameters from the AgentCore stack
2. Generates `config.js` with the correct values
3. Deploys the S3 + CloudFront stack (`cdk/`)
4. Re-deploys the AgentCore stack to add the CloudFront URL to Cognito callback URLs

### Manual Steps
```bash
# 1. Generate config from SSM
bash scripts/generate-config.sh

# 2. Deploy web hosting stack
cd cdk
npx cdk deploy fixFirstAgent-WebHostingStack \
  -c cognitoUserPoolId="<POOL_ID>" \
  -c cognitoClientId="<CLIENT_ID>" \
  -c agentCoreRuntimeArn="<RUNTIME_ARN>"

# 3. Update AgentCore stack with CloudFront URL
cd ../fixFirstAgent/cdk
npx cdk deploy fixFirstAgent-AgentCoreStack \
  -c cloudfrontUrl="https://<distribution>.cloudfront.net"
```

## File Structure

```
fixFirstAgentWeb/
├── static/           # Deployed to S3
│   ├── index.html    # Chat interface (main page)
│   ├── login.html    # Sign in page
│   ├── register.html # Sign up page
│   ├── styles.css    # Shared styles
│   ├── config.js     # Runtime configuration (generated)
│   ├── auth.js       # Cognito authentication module
│   └── agent.js      # AgentCore invocation module
├── app.py            # Legacy Flask app (for local dev reference)
└── templates/        # Legacy Flask templates
```
