// ---------------------------------------------------------------------------
// Google Play Integrity Validation
//
// Verifies Play Integrity tokens to ensure the request originates from
// a genuine Android device running an unmodified copy of the app
// distributed through Google Play.
//
// Uses the same OAuth2 service account flow as FCM push notifications
// to authenticate with Google's decodeIntegrityToken API.
//
// Reference:
//   https://developer.android.com/google/play/integrity/verdict
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface PlayIntegrityParams {
  /** The integrity token received from the Android client. */
  token: string;
  /** Service account email for OAuth2 JWT flow. */
  serviceAccountEmail: string;
  /** PEM-encoded PKCS#8 private key for OAuth2 JWT signing. */
  serviceAccountKey: string;
  /** The package name we expect (e.g. "com.termopus.app"). */
  expectedPackageName: string;
  /** The nonce/challenge that was issued to the client. */
  expectedNonce: string;
  /** Expected SHA-256 digest(s) of the app signing certificate. */
  expectedCertificateDigests: string[];
  /**
   * When true, skip the certificate digest check for UNRECOGNIZED_VERSION
   * (sideloaded/debug) builds. In prod this should be false so only
   * PLAY_RECOGNIZED apps with matching digests are accepted.
   */
  allowSideloadedWithoutDigest?: boolean;
  /**
   * Device integrity enforcement level: off | log | on.
   * - off (default): accept MEETS_BASIC_INTEGRITY or higher
   * - log: require MEETS_DEVICE_INTEGRITY or higher, but only warn if basic (allow through)
   * - on: require MEETS_DEVICE_INTEGRITY or higher, reject if only basic
   */
  requireDeviceIntegrity?: string;
}

/**
 * Result of Play Integrity validation with extracted verdict details.
 */
export interface PlayIntegrityResult {
  valid: boolean;
  /** Device integrity labels when valid. */
  deviceVerdicts?: DeviceRecognitionVerdict[];
  /** App licensing verdict when valid. */
  licensingVerdict?: AppLicensingVerdict;
  /** Error message when invalid. */
  error?: string;
}

/**
 * Full integrity verdict returned by Google's decodeIntegrityToken API.
 */
export interface IntegrityVerdict {
  requestDetails: {
    /** Package name of the calling app. */
    requestPackageName: string;
    /** Base64-encoded nonce provided during token generation. */
    nonce: string;
    /** Timestamp (millis since epoch) when the token was generated. */
    timestampMillis: number;
  };
  appIntegrity: {
    /** Whether the app binary is recognized by Google Play. */
    appRecognitionVerdict: AppRecognitionVerdict;
    /** Package name as recognized by Play. */
    packageName?: string;
    /** Certificate SHA-256 digest(s). */
    certificateSha256Digest?: string[];
    /** Version code as recognized by Play. */
    versionCode?: number;
  };
  deviceIntegrity: {
    /** Array of device integrity labels. */
    deviceRecognitionVerdict: DeviceRecognitionVerdict[];
  };
  accountDetails: {
    /** Whether the user's Google Play account is licensed for this app. */
    appLicensingVerdict: AppLicensingVerdict;
  };
}

export type AppRecognitionVerdict =
  | 'PLAY_RECOGNIZED'
  | 'UNRECOGNIZED_VERSION'
  | 'UNEVALUATED';

export type DeviceRecognitionVerdict =
  | 'MEETS_DEVICE_INTEGRITY'
  | 'MEETS_BASIC_INTEGRITY'
  | 'MEETS_STRONG_INTEGRITY'
  | 'MEETS_VIRTUAL_INTEGRITY';

export type AppLicensingVerdict =
  | 'LICENSED'
  | 'UNLICENSED'
  | 'UNEVALUATED';

/**
 * Shape of the response from Google's decodeIntegrityToken endpoint.
 */
interface DecodeTokenResponse {
  tokenPayloadExternal: IntegrityVerdict;
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const PLAY_INTEGRITY_API_BASE = 'https://playintegrity.googleapis.com/v1';

/** Maximum age of an integrity token before we reject it (5 minutes). */
const MAX_TOKEN_AGE_MS = 5 * 60 * 1000;

/** Cached OAuth2 access token with expiry. */
let cachedAccessToken: { token: string; expiresAt: number } | null = null;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Validate a Google Play Integrity token.
 *
 * Calls Google's server-side API to decode the token, then verifies:
 *  1. The nonce matches the challenge issued by the server.
 *  2. The package name matches the expected app.
 *  3. The app signing certificate matches the expected digest.
 *  4. The app is recognized by Google Play (PLAY_RECOGNIZED).
 *  5. The device meets at least basic integrity (MEETS_BASIC_INTEGRITY).
 *  6. The token is not stale (generated within the last 5 minutes).
 *
 * Returns a result object with validation status and details.
 */
export async function validatePlayIntegrity(
  params: PlayIntegrityParams,
): Promise<PlayIntegrityResult> {
  // Handle fallback tokens from devices without Play Services.
  // Use trim() + toLowerCase() to prevent bypass via leading/trailing whitespace
  // or mixed-case variants (e.g. "Fallback:", "FALLBACK:", " fallback:").
  if (params.token.trim().toLowerCase().startsWith('fallback:')) {
    console.warn('Received fallback attestation token (no Play Services)');
    return {
      valid: false,
      error: 'Device sent fallback attestation — Play Integrity unavailable on device',
    };
  }

  // Need service account credentials to call Google's API
  if (!params.serviceAccountEmail || !params.serviceAccountKey) {
    console.error('Missing service account credentials for Play Integrity validation');
    return {
      valid: false,
      error: 'Server-side Play Integrity credentials not configured',
    };
  }

  try {
    // ---- 0. Get OAuth2 access token -----------------------------------------
    const accessToken = await getOAuth2AccessToken(
      params.serviceAccountEmail,
      params.serviceAccountKey,
    );
    if (!accessToken) {
      return {
        valid: false,
        error: 'Failed to obtain OAuth2 access token for Play Integrity API',
      };
    }

    // ---- 1. Decode the integrity token via Google's API --------------------
    // API URL format: /v1/{packageName}:decodeIntegrityToken
    const apiUrl =
      `${PLAY_INTEGRITY_API_BASE}/${params.expectedPackageName}:decodeIntegrityToken`;

    const response = await fetch(apiUrl, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        integrity_token: params.token,
      }),
    });

    if (!response.ok) {
      const errorBody = await response.text();
      console.error(
        `Play Integrity API error (HTTP ${response.status}):`,
        errorBody,
      );
      return {
        valid: false,
        error: `Play Integrity API error (HTTP ${response.status}): ${errorBody}`,
      };
    }

    const result = (await response.json()) as DecodeTokenResponse;
    const verdict = result.tokenPayloadExternal;

    if (!verdict) {
      console.error('Play Integrity API returned empty verdict');
      return { valid: false, error: 'Play Integrity API returned empty verdict' };
    }

    // ---- 2. Verify nonce (challenge binding) --------------------------------
    // The Android client SHA-256 hashes the challenge and base64url-encodes it
    // before passing to Play Integrity. We must hash the expected nonce the
    // same way before comparing.
    const receivedNonce = verdict.requestDetails?.nonce;
    if (!receivedNonce) {
      console.error('No nonce in integrity verdict');
      return { valid: false, error: 'No nonce in integrity verdict' };
    }

    const expectedHash = await crypto.subtle.digest(
      'SHA-256',
      new TextEncoder().encode(params.expectedNonce),
    );
    const expectedNonceHashed = uint8ArrayToBase64Url(new Uint8Array(expectedHash));

    if (receivedNonce !== expectedNonceHashed) {
      console.error(
        `Nonce mismatch: expected ${expectedNonceHashed}, got ${receivedNonce}`,
      );
      return { valid: false, error: 'Nonce mismatch — possible replay attack' };
    }

    // ---- 3. Verify package name ---------------------------------------------
    const requestPackageName = verdict.requestDetails?.requestPackageName;
    if (requestPackageName !== params.expectedPackageName) {
      console.error(
        `Package name mismatch: expected ${params.expectedPackageName}, got ${requestPackageName}`,
      );
      return {
        valid: false,
        error: `Package name mismatch: expected ${params.expectedPackageName}, got ${requestPackageName}`,
      };
    }

    // Also check appIntegrity packageName if present
    const appPackageName = verdict.appIntegrity?.packageName;
    if (appPackageName && appPackageName !== params.expectedPackageName) {
      console.error(
        `App integrity package name mismatch: expected ${params.expectedPackageName}, got ${appPackageName}`,
      );
      return {
        valid: false,
        error: `App integrity package name mismatch`,
      };
    }

    // ---- 4. Verify app integrity (PLAY_RECOGNIZED) --------------------------
    // Check app verdict BEFORE certificate digest so we know if the build is
    // sideloaded when deciding whether to enforce the digest.
    const appVerdict = verdict.appIntegrity?.appRecognitionVerdict;
    const isSideloaded = appVerdict === 'UNRECOGNIZED_VERSION';

    if (params.allowSideloadedWithoutDigest) {
      // Dev environment: accept PLAY_RECOGNIZED and UNRECOGNIZED_VERSION
      if (!appVerdict || !['PLAY_RECOGNIZED', 'UNRECOGNIZED_VERSION'].includes(appVerdict)) {
        console.error(`App not recognized by Play: ${appVerdict}`);
        return {
          valid: false,
          error: `App not recognized by Play: ${appVerdict}`,
        };
      }
    } else {
      // Prod environment: only accept PLAY_RECOGNIZED
      if (!appVerdict || appVerdict !== 'PLAY_RECOGNIZED') {
        console.error(`App not recognized by Play: ${appVerdict} (prod requires PLAY_RECOGNIZED)`);
        return {
          valid: false,
          error: `App not recognized by Play: ${appVerdict}`,
        };
      }
    }

    if (isSideloaded) {
      console.log('[provision] Warning: app is UNRECOGNIZED_VERSION (sideloaded/debug build)');
    }

    // ---- 5. Verify app signing certificate digest ---------------------------
    // Play Integrity returns digests as base64url (no padding), but the
    // ANDROID_CERTIFICATE_DIGESTS secret may use colon-separated hex
    // (e.g. "57:98:A8:..."). Normalize both to lowercase hex for comparison.
    //
    // Skip the digest check for sideloaded/debug builds in dev — debug APKs
    // use the Android debug keystore which won't match the Play Store cert.
    const skipDigestForSideloaded = isSideloaded && params.allowSideloadedWithoutDigest;

    if (
      !skipDigestForSideloaded &&
      params.expectedCertificateDigests.length > 0 &&
      verdict.appIntegrity?.certificateSha256Digest
    ) {
      const receivedDigests = verdict.appIntegrity.certificateSha256Digest;
      const normalizedExpected = params.expectedCertificateDigests.map(normalizeDigest);
      const normalizedReceived = receivedDigests.map(normalizeDigest);

      const hasMatchingDigest = normalizedReceived.some((digest) =>
        normalizedExpected.includes(digest),
      );

      if (!hasMatchingDigest) {
        console.error(
          `Certificate digest mismatch. Expected one of [${params.expectedCertificateDigests.join(', ')}], ` +
          `got [${receivedDigests.join(', ')}]`,
        );
        return {
          valid: false,
          error: 'App signing certificate digest mismatch',
        };
      }
    } else if (skipDigestForSideloaded) {
      console.log('[provision] Skipping certificate digest check for sideloaded/debug build (dev env)');
    }

    // ---- 6. Verify device integrity ----------------------------------------
    const deviceVerdicts = verdict.deviceIntegrity?.deviceRecognitionVerdict;
    if (!Array.isArray(deviceVerdicts) || deviceVerdicts.length === 0) {
      console.error('No device integrity verdicts returned');
      return { valid: false, error: 'No device integrity verdicts returned' };
    }

    // Minimum acceptable verdicts depend on enforcement level.
    // off (default): accept MEETS_BASIC_INTEGRITY or higher
    // log: require MEETS_DEVICE_INTEGRITY or higher, warn if only basic
    // on: require MEETS_DEVICE_INTEGRITY or higher, reject if only basic
    const deviceIntegrityMode = (params.requireDeviceIntegrity ?? 'off').toLowerCase();
    if (!['off', 'log', 'on'].includes(deviceIntegrityMode)) {
      console.error(`[integrity] Invalid REQUIRE_DEVICE_INTEGRITY value: "${deviceIntegrityMode}", defaulting to "off"`);
    }

    const acceptableDeviceVerdicts: DeviceRecognitionVerdict[] = [
      'MEETS_BASIC_INTEGRITY',
      'MEETS_DEVICE_INTEGRITY',
      'MEETS_STRONG_INTEGRITY',
    ];
    const hasAcceptableDevice = deviceVerdicts.some((v) =>
      acceptableDeviceVerdicts.includes(v),
    );
    if (!hasAcceptableDevice) {
      console.error(
        `Device does not meet integrity requirements. Verdicts: ${deviceVerdicts.join(', ')}`,
      );
      return {
        valid: false,
        error: `Device does not meet integrity requirements. Verdicts: ${deviceVerdicts.join(', ')}`,
      };
    }

    // Check if device meets the elevated DEVICE_INTEGRITY requirement
    if (deviceIntegrityMode !== 'off') {
      const strongVerdicts: DeviceRecognitionVerdict[] = [
        'MEETS_DEVICE_INTEGRITY',
        'MEETS_STRONG_INTEGRITY',
      ];
      const meetsDeviceIntegrity = deviceVerdicts.some((v) =>
        strongVerdicts.includes(v),
      );

      if (!meetsDeviceIntegrity) {
        if (deviceIntegrityMode === 'on') {
          console.error(
            `Device only meets BASIC integrity — DEVICE_INTEGRITY required. Verdicts: ${deviceVerdicts.join(', ')}`,
          );
          return {
            valid: false,
            error: `Device does not meet DEVICE_INTEGRITY requirement. Verdicts: ${deviceVerdicts.join(', ')}`,
          };
        } else {
          // log mode: warn but allow through
          console.warn(
            `[integrity] WARN: Device only meets BASIC integrity (log mode). Verdicts: ${deviceVerdicts.join(', ')}`,
          );
        }
      }
    }

    // ---- 7. Verify token freshness -----------------------------------------
    const tokenTimestamp = verdict.requestDetails?.timestampMillis;
    if (tokenTimestamp !== undefined && tokenTimestamp !== null) {
      const tokenAge = Date.now() - tokenTimestamp;
      if (tokenAge > MAX_TOKEN_AGE_MS) {
        console.error(
          `Integrity token is stale: ${tokenAge}ms old (max ${MAX_TOKEN_AGE_MS}ms)`,
        );
        return {
          valid: false,
          error: `Integrity token is stale: ${tokenAge}ms old`,
        };
      }
      if (tokenAge < -60_000) {
        // Allow 1 minute of clock skew
        console.error('Integrity token timestamp is too far in the future');
        return {
          valid: false,
          error: 'Integrity token timestamp is in the future',
        };
      }
    }

    // ---- 8. All checks passed -----------------------------------------------
    console.log(
      'Play Integrity validated:',
      `app=${appVerdict},`,
      `device=[${deviceVerdicts.join(',')}],`,
      `license=${verdict.accountDetails?.appLicensingVerdict ?? 'unknown'},`,
      `package=${requestPackageName}`,
    );

    return {
      valid: true,
      deviceVerdicts,
      licensingVerdict: verdict.accountDetails?.appLicensingVerdict,
    };
  } catch (error) {
    console.error('Play Integrity validation error:', error);
    return {
      valid: false,
      error: `Play Integrity validation error: ${error instanceof Error ? error.message : String(error)}`,
    };
  }
}

// ---------------------------------------------------------------------------
// OAuth2 Token Generation (same pattern as FCM push)
// ---------------------------------------------------------------------------

/**
 * Obtain an OAuth2 access token for the Play Integrity API using a service
 * account. Uses the JWT Bearer assertion flow.
 */
async function getOAuth2AccessToken(
  serviceAccountEmail: string,
  serviceAccountKey: string,
): Promise<string | null> {
  // Check cache
  if (cachedAccessToken && Date.now() < cachedAccessToken.expiresAt) {
    return cachedAccessToken.token;
  }

  try {
    const now = Math.floor(Date.now() / 1000);
    const expiry = now + 3600; // 1 hour

    const header = { alg: 'RS256', typ: 'JWT' };
    const claims = {
      iss: serviceAccountEmail,
      scope: 'https://www.googleapis.com/auth/playintegrity',
      aud: 'https://oauth2.googleapis.com/token',
      iat: now,
      exp: expiry,
    };

    const encodedHeader = base64UrlEncode(JSON.stringify(header));
    const encodedClaims = base64UrlEncode(JSON.stringify(claims));
    const signingInput = `${encodedHeader}.${encodedClaims}`;

    const privateKey = await importServiceAccountKey(serviceAccountKey);
    const signature = await crypto.subtle.sign(
      { name: 'RSASSA-PKCS1-v1_5' },
      privateKey,
      new TextEncoder().encode(signingInput),
    );

    const encodedSignature = base64UrlEncodeBuffer(signature);
    const jwt = `${signingInput}.${encodedSignature}`;

    const tokenResponse = await fetch('https://oauth2.googleapis.com/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
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
    };

    cachedAccessToken = {
      token: tokenResult.access_token,
      expiresAt: Date.now() + (tokenResult.expires_in - 300) * 1000,
    };

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
    { name: 'RSASSA-PKCS1-v1_5', hash: { name: 'SHA-256' } },
    false,
    ['sign'],
  );
}

function base64UrlEncode(str: string): string {
  return btoa(str).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** Base64url encode keeping padding (matches Android Base64.URL_SAFE | NO_WRAP). */
function uint8ArrayToBase64Url(bytes: Uint8Array): string {
  let binary = '';
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_');
}

/**
 * Normalize a certificate digest to lowercase hex (no separators).
 *
 * Handles:
 * - Colon-separated hex: "57:98:A8:..." → "5798a8..."
 * - Base64url (with or without padding): "vWF_AN..." → "bd617f00..."
 * - Plain hex: "5798a8..." → "5798a8..."
 */
function normalizeDigest(digest: string): string {
  // Colon-separated hex
  if (digest.includes(':')) {
    return digest.replace(/:/g, '').toLowerCase();
  }
  // Base64url — contains non-hex chars like - _ or uppercase beyond F
  if (/[^0-9a-fA-F]/.test(digest) || digest.length < 64) {
    try {
      const b64 = digest.replace(/-/g, '+').replace(/_/g, '/');
      const padded = b64 + '='.repeat((4 - (b64.length % 4)) % 4);
      const binary = atob(padded);
      return Array.from(binary, (c) => c.charCodeAt(0).toString(16).padStart(2, '0')).join('');
    } catch {
      return digest.toLowerCase();
    }
  }
  // Already hex
  return digest.toLowerCase();
}

function base64UrlEncodeBuffer(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  let binary = '';
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
