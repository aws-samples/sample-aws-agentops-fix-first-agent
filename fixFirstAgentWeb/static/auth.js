/**
 * Cognito authentication module using USER_PASSWORD_AUTH flow.
 * Calls Cognito InitiateAuth / SignUp directly via the public API.
 */
const Auth = (() => {
  const COGNITO_ENDPOINT = () =>
    `https://cognito-idp.${APP_CONFIG.REGION}.amazonaws.com/`;

  const SESSION_KEYS = {
    accessToken: 'fixfirst_access_token',
    idToken: 'fixfirst_id_token',
    refreshToken: 'fixfirst_refresh_token',
    username: 'fixfirst_username',
    userId: 'fixfirst_user_id',
    email: 'fixfirst_email',
  };

  async function cognitoRequest(action, payload) {
    const res = await fetch(COGNITO_ENDPOINT(), {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-amz-json-1.1',
        'X-Amz-Target': `AWSCognitoIdentityProviderService.${action}`,
      },
      body: JSON.stringify(payload),
    });
    const data = await res.json();
    if (!res.ok) {
      throw new Error(data.message || data.__type || 'Cognito request failed');
    }
    return data;
  }

  async function signIn(username, password) {
    const data = await cognitoRequest('InitiateAuth', {
      AuthFlow: 'USER_PASSWORD_AUTH',
      ClientId: APP_CONFIG.COGNITO_CLIENT_ID,
      AuthParameters: { USERNAME: username, PASSWORD: password },
    });

    const result = data.AuthenticationResult;
    sessionStorage.setItem(SESSION_KEYS.accessToken, result.AccessToken);
    sessionStorage.setItem(SESSION_KEYS.idToken, result.IdToken);
    if (result.RefreshToken) {
      sessionStorage.setItem(SESSION_KEYS.refreshToken, result.RefreshToken);
    }
    sessionStorage.setItem(SESSION_KEYS.username, username);

    // Fetch user attributes
    const user = await cognitoRequest('GetUser', {
      AccessToken: result.AccessToken,
    });
    const attrs = {};
    (user.UserAttributes || []).forEach((a) => (attrs[a.Name] = a.Value));
    sessionStorage.setItem(SESSION_KEYS.userId, attrs.sub || '');
    sessionStorage.setItem(SESSION_KEYS.email, attrs.email || '');

    return { username, userId: attrs.sub, email: attrs.email };
  }

  async function signUp(username, email, password) {
    await cognitoRequest('SignUp', {
      ClientId: APP_CONFIG.COGNITO_CLIENT_ID,
      Username: username,
      Password: password,
      UserAttributes: [{ Name: 'email', Value: email }],
    });
  }

  async function confirmSignUp(username, code) {
    await cognitoRequest('ConfirmSignUp', {
      ClientId: APP_CONFIG.COGNITO_CLIENT_ID,
      Username: username,
      ConfirmationCode: code,
    });
  }

  async function resendConfirmationCode(username) {
    await cognitoRequest('ResendConfirmationCode', {
      ClientId: APP_CONFIG.COGNITO_CLIENT_ID,
      Username: username,
    });
  }

  async function refreshSession() {
    const refreshToken = sessionStorage.getItem(SESSION_KEYS.refreshToken);
    if (!refreshToken) throw new Error('No refresh token');

    const data = await cognitoRequest('InitiateAuth', {
      AuthFlow: 'REFRESH_TOKEN_AUTH',
      ClientId: APP_CONFIG.COGNITO_CLIENT_ID,
      AuthParameters: { REFRESH_TOKEN: refreshToken },
    });

    const result = data.AuthenticationResult;
    sessionStorage.setItem(SESSION_KEYS.accessToken, result.AccessToken);
    sessionStorage.setItem(SESSION_KEYS.idToken, result.IdToken);
    return result.AccessToken;
  }

  function signOut() {
    Object.values(SESSION_KEYS).forEach((k) => sessionStorage.removeItem(k));
  }

  function getAccessToken() {
    return sessionStorage.getItem(SESSION_KEYS.accessToken);
  }

  function getUsername() {
    return sessionStorage.getItem(SESSION_KEYS.username);
  }

  function getUserId() {
    return sessionStorage.getItem(SESSION_KEYS.userId);
  }

  function isAuthenticated() {
    return !!getAccessToken();
  }

  return {
    signIn,
    signUp,
    confirmSignUp,
    resendConfirmationCode,
    signOut,
    refreshSession,
    getAccessToken,
    getUsername,
    getUserId,
    isAuthenticated,
  };
})();
