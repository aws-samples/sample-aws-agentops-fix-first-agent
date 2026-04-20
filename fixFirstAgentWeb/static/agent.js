/**
 * AgentCore Runtime invocation module.
 * Calls the Bedrock AgentCore Runtime endpoint using the Cognito bearer token.
 */
const Agent = (() => {
  let sessionId = crypto.randomUUID();

  function getEndpointUrl() {
    const escapedArn = encodeURIComponent(APP_CONFIG.AGENTCORE_RUNTIME_ARN);
    return `https://bedrock-agentcore.${APP_CONFIG.REGION}.amazonaws.com/runtimes/${escapedArn}/invocations?qualifier=DEFAULT`;
  }

  async function invoke(prompt, bearerToken, userId) {
    const url = getEndpointUrl();
    const response = await fetch(url, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${bearerToken}`,
        'Content-Type': 'application/json',
        'X-Amzn-Trace-Id': `trace-id-${crypto.randomUUID()}`,
        'X-Amzn-Bedrock-AgentCore-Runtime-Session-Id': sessionId,
        'X-Amzn-Bedrock-AgentCore-Runtime-Custom-User-Id': userId || 'UNKNOWN',
      },
      body: JSON.stringify({ prompt }),
    });

    if (!response.ok) {
      const errBody = await response.text();
      throw new Error(`Agent invocation failed (${response.status}): ${errBody}`);
    }
    return response.json();
  }

  /**
   * Invoke with automatic token refresh on 401.
   */
  async function invokeWithRetry(prompt) {
    let token = Auth.getAccessToken();
    const userId = Auth.getUserId();

    try {
      return await invoke(prompt, token, userId);
    } catch (err) {
      if (err.message.includes('401') || err.message.toLowerCase().includes('unauthorized')) {
        // Try refreshing the token once
        try {
          token = await Auth.refreshSession();
          return await invoke(prompt, token, userId);
        } catch {
          throw new Error('Session expired. Please sign in again.');
        }
      }
      throw err;
    }
  }

  function resetSession() {
    sessionId = crypto.randomUUID();
    return sessionId;
  }

  function getSessionId() {
    return sessionId;
  }

  return { invokeWithRetry, resetSession, getSessionId };
})();
