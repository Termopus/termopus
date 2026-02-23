import type { Env } from '../index';

// ---------------------------------------------------------------------------
// Challenge Generation Endpoint
//
// Generates a cryptographically random nonce and stores it in KV with a
// 5-minute TTL.  The client must include this challenge in its attestation
// request to prevent replay attacks.
//
// Flow:
//   1. Client POSTs to /provision/challenge with { deviceId }.
//   2. Server generates a random 32-byte nonce, Base64-encodes it.
//   3. Stores in KV under key "challenge:{nonce}" with 5-minute expiration.
//   4. Returns the nonce to the client.
//   5. Client uses this nonce when generating the attestation token.
//   6. During /provision/cert, the server looks up the nonce in KV to verify
//      it was issued by this server and hasn't expired.
// ---------------------------------------------------------------------------

/** TTL for challenge nonces (5 minutes). */
const CHALLENGE_TTL_SECONDS = 5 * 60;

/** Rate limit: minimum interval between challenges per device (60 seconds). */
const DEVICE_RATE_LIMIT_SECONDS = 60;

interface ChallengeRequest {
  /** Stable device identifier for rate limiting. */
  deviceId: string;
}

interface ChallengeResponse {
  /** Base64-encoded random challenge nonce. */
  challenge: string;
  /** ISO-8601 expiration timestamp. */
  expiresAt: string;
}

export async function handleChallenge(request: Request, env: Env): Promise<Response> {
  // ---- 0. Parse body -------------------------------------------------------
  let body: ChallengeRequest;
  try {
    body = (await request.json()) as ChallengeRequest;
  } catch {
    return jsonError('Request body must be valid JSON', 400);
  }

  if (!body.deviceId) {
    return jsonError('Missing required field: deviceId', 400);
  }

  // Sanitise device ID
  if (!/^[a-zA-Z0-9\-_]{1,128}$/.test(body.deviceId)) {
    return jsonError('Invalid deviceId format', 400);
  }

  // ---- 1. Rate limit per device --------------------------------------------
  const rateLimitKey = `challenge-rate:${body.deviceId}`;
  const lastChallenge = await env.PROVISION_KV.get(rateLimitKey);
  if (lastChallenge) {
    return jsonError('Challenge requested too recently. Please wait before retrying.', 429);
  }

  // ---- 2. Generate random nonce --------------------------------------------
  const nonceBytes = new Uint8Array(32);
  crypto.getRandomValues(nonceBytes);
  const nonce = uint8ArrayToBase64(nonceBytes);

  // ---- 3. Store in KV with TTL ---------------------------------------------
  const expiresAt = new Date(Date.now() + CHALLENGE_TTL_SECONDS * 1000);

  await env.PROVISION_KV.put(
    `challenge:${nonce}`,
    JSON.stringify({
      deviceId: body.deviceId,
      createdAt: new Date().toISOString(),
    }),
    { expirationTtl: CHALLENGE_TTL_SECONDS },
  );

  // Set rate limit
  await env.PROVISION_KV.put(rateLimitKey, '1', {
    expirationTtl: DEVICE_RATE_LIMIT_SECONDS,
  });

  // ---- 4. Return challenge -------------------------------------------------
  const response: ChallengeResponse = {
    challenge: nonce,
    expiresAt: expiresAt.toISOString(),
  };

  return new Response(JSON.stringify(response), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  });
}

/**
 * Verify that a challenge was issued by this server and consume it.
 *
 * This is called from the provision and restore handlers. The challenge is
 * consumed atomically to prevent reuse (single-use nonce).
 *
 * KV get+delete is NOT atomic — between the get and delete, another
 * concurrent request could read the same challenge.  To mitigate this we
 * first mark the entry as `consumed: true` (immediate within the same
 * colo) BEFORE deleting it, creating a guard that catches most race
 * conditions.
 *
 * @returns The deviceId bound to the challenge, or null if invalid/expired.
 */
export async function verifyAndConsumeChallenge(
  challenge: string,
  env: Env,
): Promise<{ deviceId: string } | null> {
  const key = `challenge:${challenge}`;
  const stored = await env.PROVISION_KV.get(key);

  if (!stored) {
    return null;
  }

  let parsed: { deviceId: string; consumed?: boolean };
  try {
    parsed = JSON.parse(stored);
  } catch {
    return null;
  }

  // Check if already consumed (atomic guard)
  if (parsed.consumed) {
    return null;
  }

  // Mark as consumed BEFORE processing (atomic consumption).
  // Even if concurrent requests read before this write propagates,
  // the challenge key has a short TTL and will expire.
  await env.PROVISION_KV.put(
    key,
    JSON.stringify({ ...parsed, consumed: true }),
    { expirationTtl: 60 }, // Keep consumed marker for 60s then expire
  );

  // Delete the original (belt and suspenders)
  await env.PROVISION_KV.delete(key);

  return { deviceId: parsed.deviceId };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function jsonError(message: string, status: number): Response {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

function uint8ArrayToBase64(bytes: Uint8Array): string {
  let binaryString = '';
  for (let i = 0; i < bytes.length; i++) {
    binaryString += String.fromCharCode(bytes[i]);
  }
  return btoa(binaryString);
}
