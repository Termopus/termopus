/**
 * FCM push notification sender.
 *
 * Uses the FCM v1 API (https://fcm.googleapis.com/v1/projects/{project}/messages:send)
 * with OAuth2 service account authentication.
 *
 * Falls back to the legacy API if v1 credentials are not configured.
 */

import type { Env } from './types';

/** Result of a push notification attempt. */
export type PushResult = 'success' | 'unregistered' | 'error';

/**
 * Parameters accepted by sendPushNotification.
 *
 * This is a **data-only silent push**. No notification title or body is
 * included — the mobile app wakes in the background, reconnects the
 * encrypted WebSocket, fetches the real content, and creates a *local*
 * notification on-device. This means Google/Apple never see any
 * content — not even a generic "Action required" string.
 */
interface PushMessage {
  token: string;
  data: Record<string, string>;
  /** Collapse key — FCM keeps only the latest message per key when offline. */
  collapseKey?: string;
}

/** FCM v1 API message structure (data-only, no notification field). */
interface FcmV1Message {
  message: {
    token: string;
    /** Data-only payload — no `notification` key. */
    data: Record<string, string>;
    android?: {
      priority: 'HIGH' | 'NORMAL';
      ttl: string;
    };
    apns?: {
      headers?: Record<string, string>;
      payload: {
        aps: {
          /** content-available: 1 wakes the app silently in the background. */
          'content-available': number;
        };
      };
    };
  };
}

/** FCM v1 API response shape. */
interface FcmV1Response {
  name?: string;
  error?: {
    code: number;
    message: string;
    status: string;
  };
}

/** Legacy FCM response shape. */
interface FcmLegacyResponse {
  success: number;
  failure: number;
  results?: Array<{
    message_id?: string;
    error?: string;
  }>;
}

/** Cached OAuth2 access token with expiry. */
let cachedAccessToken: { token: string; expiresAt: number } | null = null;

/**
 * Send a push notification via Firebase Cloud Messaging.
 *
 * Prefers the v1 API if project ID and service account credentials are
 * available. Falls back to the legacy API with a server key.
 *
 * @param env      Worker environment bindings.
 * @param message  The notification to send.
 * @returns `'success'` if FCM accepted the message, `'unregistered'` if the
 *          token is stale (404/410), or `'error'` on other failures.
 */
export async function sendPushNotification(
  env: Env,
  message: PushMessage,
): Promise<PushResult> {
  if (!message.token) {
    console.error('FCM token is empty; cannot send push');
    return 'error';
  }

  if (!message.data || Object.keys(message.data).length === 0) {
    console.error('FCM data payload is empty; nothing to send');
    return 'error';
  }

  // Prefer v1 API
  if (env.FCM_PROJECT_ID && env.FCM_SERVICE_ACCOUNT_EMAIL && env.FCM_SERVICE_ACCOUNT_KEY) {
    return sendViaV1API(env, message);
  }

  // Fall back to legacy API
  if (env.FCM_SERVER_KEY) {
    return sendViaLegacyAPI(env.FCM_SERVER_KEY, message);
  }

  console.error('No FCM credentials configured (neither v1 nor legacy)');
  return 'error';
}

// ---------------------------------------------------------------------------
// FCM v1 API
// ---------------------------------------------------------------------------

async function sendViaV1API(env: Env, message: PushMessage): Promise<PushResult> {
  try {
    const accessToken = await getOAuth2AccessToken(env);
    if (!accessToken) {
      console.error('Failed to obtain OAuth2 access token for FCM');
      return 'error';
    }

    // Data-only silent push — no `notification` key.
    // The app wakes, reconnects WebSocket, fetches content, and
    // creates a local notification entirely on-device.
    const fcmMessage: FcmV1Message = {
      message: {
        token: message.token,
        data: message.data,
        android: {
          priority: 'HIGH',
          ttl: '300s',
          ...(message.collapseKey && { collapse_key: message.collapseKey }),
        },
        apns: {
          headers: {
            'apns-priority': '5',
            'apns-push-type': 'background',
            ...(message.collapseKey && { 'apns-collapse-id': message.collapseKey }),
          },
          payload: {
            aps: {
              'content-available': 1,
            },
          },
        },
      },
    };

    const url = `https://fcm.googleapis.com/v1/projects/${env.FCM_PROJECT_ID}/messages:send`;

    const response = await fetch(url, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(fcmMessage),
    });

    if (!response.ok) {
      const errorBody = await response.text();
      console.error(`FCM v1 API error (HTTP ${response.status}): ${errorBody}`);

      // Handle specific error codes
      if (response.status === 404 || response.status === 410) {
        // Token is no longer valid
        console.warn('FCM token is no longer valid (UNREGISTERED)');
        return 'unregistered';
      }

      return 'error';
    }

    const result = (await response.json()) as FcmV1Response;
    if (result.error) {
      console.error(`FCM v1 error: ${result.error.message} (${result.error.status})`);
      return 'error';
    }

    return 'success';
  } catch (error) {
    console.error('FCM v1 push exception:', error);
    return 'error';
  }
}

/**
 * Obtain an OAuth2 access token for the FCM v1 API using a service account.
 *
 * Uses the JWT Bearer assertion flow:
 * 1. Build a JWT signed with the service account private key.
 * 2. Exchange the JWT for an access token at Google's token endpoint.
 * 3. Cache the token until it expires.
 */
async function getOAuth2AccessToken(env: Env): Promise<string | null> {
  // Check cache
  if (cachedAccessToken && Date.now() < cachedAccessToken.expiresAt) {
    return cachedAccessToken.token;
  }

  try {
    const now = Math.floor(Date.now() / 1000);
    const expiry = now + 3600; // 1 hour

    // Build JWT header
    const header = {
      alg: 'RS256',
      typ: 'JWT',
    };

    // Build JWT claims
    const claims = {
      iss: env.FCM_SERVICE_ACCOUNT_EMAIL,
      scope: 'https://www.googleapis.com/auth/firebase.messaging',
      aud: 'https://oauth2.googleapis.com/token',
      iat: now,
      exp: expiry,
    };

    // Encode header and claims
    const encodedHeader = base64UrlEncode(JSON.stringify(header));
    const encodedClaims = base64UrlEncode(JSON.stringify(claims));
    const signingInput = `${encodedHeader}.${encodedClaims}`;

    // Import the private key and sign
    const privateKey = await importServiceAccountKey(env.FCM_SERVICE_ACCOUNT_KEY);
    const signature = await crypto.subtle.sign(
      { name: 'RSASSA-PKCS1-v1_5' },
      privateKey,
      new TextEncoder().encode(signingInput),
    );

    const encodedSignature = base64UrlEncodeBuffer(signature);
    const jwt = `${signingInput}.${encodedSignature}`;

    // Exchange JWT for access token
    const tokenResponse = await fetch('https://oauth2.googleapis.com/token', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwt}`,
    });

    if (!tokenResponse.ok) {
      const errorBody = await tokenResponse.text();
      console.error(`OAuth2 token exchange failed (HTTP ${tokenResponse.status}): ${errorBody}`);
      return null;
    }

    const tokenResult = (await tokenResponse.json()) as {
      access_token: string;
      expires_in: number;
      token_type: string;
    };

    // Cache the token (with 5-minute safety margin).
    // Only update if this token expires later than the current one,
    // preventing a concurrent stale fetch from overwriting a fresh token.
    const newExpiresAt = Date.now() + (tokenResult.expires_in - 300) * 1000;
    if (!cachedAccessToken || newExpiresAt > cachedAccessToken.expiresAt) {
      cachedAccessToken = {
        token: tokenResult.access_token,
        expiresAt: newExpiresAt,
      };
    }

    return tokenResult.access_token;
  } catch (error) {
    console.error('OAuth2 access token generation failed:', error);
    return null;
  }
}

/**
 * Import a PEM-encoded PKCS#8 RSA private key for JWT signing.
 */
async function importServiceAccountKey(pemKey: string): Promise<CryptoKey> {
  // Strip PEM headers and decode
  const base64 = pemKey
    .replace(/-----BEGIN PRIVATE KEY-----/g, '')
    .replace(/-----END PRIVATE KEY-----/g, '')
    .replace(/\s+/g, '');

  const binaryString = atob(base64);
  const keyData = new Uint8Array(binaryString.length);
  for (let i = 0; i < binaryString.length; i++) {
    keyData[i] = binaryString.charCodeAt(i);
  }

  return crypto.subtle.importKey(
    'pkcs8',
    keyData.buffer,
    {
      name: 'RSASSA-PKCS1-v1_5',
      hash: { name: 'SHA-256' },
    },
    false,
    ['sign'],
  );
}

function base64UrlEncode(str: string): string {
  return btoa(str).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function base64UrlEncodeBuffer(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  let binary = '';
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

// ---------------------------------------------------------------------------
// Legacy FCM API (fallback)
// ---------------------------------------------------------------------------

async function sendViaLegacyAPI(
  serverKey: string,
  message: PushMessage,
): Promise<PushResult> {
  if (!serverKey) {
    console.error('FCM server key is not configured');
    return 'error';
  }

  // Data-only silent push — no `notification` key.
  const payload = {
    to: message.token,
    data: message.data,
    priority: 'high',
    content_available: true,
    time_to_live: 300,
    ...(message.collapseKey && { collapse_key: message.collapseKey }),
  };

  try {
    const response = await fetch('https://fcm.googleapis.com/fcm/send', {
      method: 'POST',
      headers: {
        'Authorization': `key=${serverKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(payload),
    });

    if (!response.ok) {
      const body = await response.text();
      console.error(`FCM legacy HTTP error ${response.status}: ${body}`);
      return 'error';
    }

    const result = (await response.json()) as FcmLegacyResponse;

    if (result.failure > 0 && result.results) {
      for (const r of result.results) {
        if (r.error) {
          console.error(`FCM per-token error: ${r.error}`);
          if (r.error === 'NotRegistered' || r.error === 'InvalidRegistration') {
            console.warn('FCM token is no longer valid (UNREGISTERED)');
            return 'unregistered';
          }
        }
      }
      return 'error';
    }

    return result.success > 0 ? 'success' : 'error';
  } catch (error) {
    console.error('FCM legacy push exception:', error);
    return 'error';
  }
}
