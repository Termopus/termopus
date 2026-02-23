import type { Env } from '../index';
import { revokeCertFromAccess } from '../cloudflare/access';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface RevokeRequest {
  /** Device identifier whose certificate should be revoked. */
  deviceId: string;
  /** Optional human-readable reason for the revocation. */
  reason?: string;
}

export interface RevokeResponse {
  /** Whether the revocation succeeded. */
  success: boolean;
  /** The device ID that was revoked. */
  deviceId: string;
  /** Echoed reason, if provided. */
  reason?: string;
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

/**
 * Handle a certificate revocation request.
 *
 * Authentication: requires either:
 *   - A valid mTLS client cert (CF-Access-Client-Id header) whose fingerprint
 *     maps to the same deviceId being revoked (self-revoke), OR
 *   - An admin bearer token in the Authorization header.
 */
export async function handleRevoke(request: Request, env: Env): Promise<Response> {
  // ---- Authenticate ----------------------------------------------------------
  const authResult = await authenticateRevoke(request, env);
  if (!authResult.authenticated) {
    return jsonError(authResult.reason ?? 'Unauthorized', 401);
  }

  // ---- Parse body ----------------------------------------------------------
  let body: RevokeRequest;
  try {
    body = await request.json() as RevokeRequest;
  } catch {
    return jsonError('Request body must be valid JSON', 400);
  }

  // ---- Validate ------------------------------------------------------------
  if (!body.deviceId) {
    return jsonError('Missing required field: deviceId', 400);
  }

  if (!/^[a-zA-Z0-9\-_]{1,128}$/.test(body.deviceId)) {
    return jsonError('Invalid deviceId format', 400);
  }

  // ---- For mTLS auth, verify the cert belongs to the requesting device ------
  if (authResult.method === 'mtls' && authResult.certDeviceId) {
    if (authResult.certDeviceId !== body.deviceId) {
      return jsonError('Cannot revoke a different device\'s certificate', 403);
    }
  }

  // ---- Revoke from Cloudflare Access ---------------------------------------
  const certName = `device-${body.deviceId}`;

  let revoked: boolean;
  try {
    revoked = await revokeCertFromAccess({
      accountId: env.CF_ACCOUNT_ID,
      clientId: env.CF_ACCESS_CLIENT_ID,
      clientSecret: env.CF_ACCESS_CLIENT_SECRET,
      name: certName,
    });
  } catch (error) {
    console.error('CF Access revocation failed:', error);
    return jsonError('Certificate revocation failed', 500);
  }

  if (!revoked) {
    return jsonError('Certificate revocation failed', 500);
  }

  // ---- Clean up KV records -------------------------------------------------
  // Remove the cert fingerprint record so relay stops accepting this device
  if (authResult.certFingerprint) {
    await env.PROVISION_KV.delete(`cert:${authResult.certFingerprint}`);
  }

  // ---- Respond -------------------------------------------------------------
  if (body.reason) {
    console.log(`Certificate revoked for device ${body.deviceId}: ${body.reason}`);
  }

  const response: RevokeResponse = {
    success: true,
    deviceId: body.deviceId,
    ...(body.reason ? { reason: body.reason } : {}),
  };

  return new Response(JSON.stringify(response), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  });
}

// ---------------------------------------------------------------------------
// Auth helpers
// ---------------------------------------------------------------------------

interface AuthResult {
  authenticated: boolean;
  method?: 'mtls' | 'admin';
  reason?: string;
  certDeviceId?: string;
  certFingerprint?: string;
}

async function authenticateRevoke(request: Request, env: Env): Promise<AuthResult> {
  // 1. Check admin bearer token
  const authHeader = request.headers.get('Authorization');
  if (authHeader?.startsWith('Bearer ')) {
    const token = authHeader.slice(7);
    if (env.ADMIN_API_TOKEN && constantTimeEqual(token, env.ADMIN_API_TOKEN)) {
      return { authenticated: true, method: 'admin' };
    }
    return { authenticated: false, reason: 'Invalid admin token' };
  }

  // 2. Check mTLS client cert (CF injects this header after mTLS validation)
  const certFingerprint = request.headers.get('CF-Access-Client-Id');
  if (certFingerprint) {
    // Look up the cert fingerprint in KV to find the associated device
    const record = await env.PROVISION_KV.get(`cert:${certFingerprint}`);
    if (record) {
      try {
        const data = JSON.parse(record);
        return {
          authenticated: true,
          method: 'mtls',
          certDeviceId: data.deviceId,
          certFingerprint,
        };
      } catch {
        // Malformed KV record — treat as unauthenticated
      }
    }
    // Valid mTLS cert but no KV record — REJECT for scoped operations
    // Without a KV record, we can't verify device ownership → deny
    console.log(`[revoke] mTLS cert ${certFingerprint} has no KV record — rejecting`);
    return { authenticated: false, reason: 'Certificate not found in device registry' };
  }

  return { authenticated: false, reason: 'Authentication required. Provide mTLS client certificate or admin bearer token.' };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let result = 0;
  for (let i = 0; i < a.length; i++) {
    result |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return result === 0;
}

function jsonError(message: string, status: number): Response {
  return new Response(
    JSON.stringify({ error: message }),
    {
      status,
      headers: { 'Content-Type': 'application/json' },
    },
  );
}
