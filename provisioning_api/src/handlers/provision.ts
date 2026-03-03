import type { Env } from '../index';
import { validateAppleAttestation } from '../validation/apple';
import { validatePlayIntegrity } from '../validation/google';
import { verifyCSRSignature, signCSR } from '../crypto/csr';
import { registerCertWithAccess } from '../cloudflare/access';
import { verifyAndConsumeChallenge } from './challenge';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface ProvisionRequest {
  /** PEM-encoded PKCS#10 Certificate Signing Request. */
  csr: string;
  /** Base64-encoded platform attestation blob. */
  attestation: string;
  /** Client platform. */
  platform: 'ios' | 'android';
  /** Stable, unique device identifier (hardware-backed). */
  deviceId: string;
  /** Single-use challenge that was bound into the attestation. */
  challenge: string;
  /**
   * Android Key Attestation certificate chain (Base64-encoded DER certs).
   * Optional — present only on Android when the device supports hardware
   * key attestation. Chain order: [leaf, intermediate, ..., root].
   * Proves the CSR public key was generated in the device's TEE/StrongBox.
   */
  keyAttestationChain?: string[];
}

export interface ProvisionResponse {
  /** PEM-encoded signed client certificate. */
  certificate: string;
  /** ISO-8601 date when the certificate expires. */
  expiresAt: string;
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/** How long a provisioned client certificate is valid (48 hours). */
const CERTIFICATE_VALIDITY_DAYS = 2;

/** Allowed platform values. */
const VALID_PLATFORMS: ReadonlySet<string> = new Set(['ios', 'android']);

/** Default re-provisioning cooldown (1 hour). Override via DEVICE_COOLDOWN_SECONDS env var. */
const DEFAULT_DEVICE_COOLDOWN_SECONDS = 3600;

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

/**
 * Handle a certificate provisioning request.
 *
 * Flow:
 *  1. Parse and validate the incoming JSON body.
 *  2. Verify the challenge was issued by this server (via KV lookup).
 *  3. Check device deduplication / rate limiting.
 *  4. Verify CSR self-signature (proof-of-possession).
 *  5. Verify device attestation (Apple App Attest or Google Play Integrity).
 *  6. Verify attestation credential public key matches CSR public key.
 *  7. Sign the CSR with the CA private key to produce a client certificate.
 *  8. Register the certificate with Cloudflare Access for mTLS enforcement.
 *  9. Record device provisioning in KV.
 * 10. Return the signed certificate and its expiration date.
 */
export async function handleProvision(request: Request, env: Env): Promise<Response> {
  // ---- 0. Parse body -------------------------------------------------------
  let body: ProvisionRequest;
  try {
    body = await request.json() as ProvisionRequest;
  } catch {
    return jsonError('Request body must be valid JSON', 400);
  }

  // ---- 1. Validate required fields -----------------------------------------
  const deviceCooldownSeconds = Math.max(60, parseInt(env.DEVICE_COOLDOWN_SECONDS ?? '', 10) || DEFAULT_DEVICE_COOLDOWN_SECONDS);
  const requireIntegrity = (env.REQUIRE_DEVICE_INTEGRITY ?? 'off').toLowerCase();
  const missingFields: string[] = [];
  if (!body.csr) missingFields.push('csr');
  if (requireIntegrity !== 'off' && !body.attestation) missingFields.push('attestation');
  if (!body.platform) missingFields.push('platform');
  if (!body.deviceId) missingFields.push('deviceId');
  if (!body.challenge) missingFields.push('challenge');

  if (missingFields.length > 0) {
    return jsonError(`Missing required fields: ${missingFields.join(', ')}`, 400);
  }

  if (!VALID_PLATFORMS.has(body.platform)) {
    return jsonError('Invalid platform. Must be "ios" or "android"', 400);
  }

  // Sanitise device ID — must be SHA-256 hex (64 lowercase hex chars)
  if (!/^[0-9a-f]{64}$/.test(body.deviceId)) {
    return jsonError('Invalid deviceId format', 400);
  }

  // ---- 2. Verify server-issued challenge ------------------------------------
  const challengeData = await verifyAndConsumeChallenge(body.challenge, env);
  if (!challengeData) {
    return jsonError(
      'Invalid or expired challenge. Request a new challenge from /provision/challenge.',
      403,
    );
  }

  // Verify the challenge was issued for this device.
  // On first provisioning the hardware key doesn't exist yet, so the
  // challenge is requested with a temporary ID (non-SHA256 format).
  // After key generation, deviceId becomes SHA256(SPKI). We allow the
  // mismatch when the challenge used a temporary ID — the real binding
  // is step 4a below (deviceId == SHA256(SPKI from CSR)).
  if (challengeData.deviceId !== body.deviceId) {
    const challengeIsHardwareId = /^[0-9a-f]{64}$/.test(challengeData.deviceId);
    if (challengeIsHardwareId) {
      // Both are SHA-256 format but don't match — real device mismatch
      return jsonError('Challenge was issued for a different device', 403);
    }
    // Else: challenge had temporary ID (first-time provisioning) — allow.
    // Step 4a enforces the hardware binding.
  }

  // ---- 3. Device deduplication / rate limiting ------------------------------
  const deviceProvisionKey = `device-provisioned:${body.deviceId}`;
  const lastProvisioned = await env.PROVISION_KV.get(deviceProvisionKey);
  if (lastProvisioned) {
    return jsonError(
      'Device was recently provisioned. Please wait before re-provisioning.',
      429,
    );
  }

  // ---- 4. Verify CSR self-signature (proof-of-possession) -------------------
  const csrData = await verifyCSRSignature(body.csr);
  if (!csrData) {
    return jsonError(
      'CSR signature verification failed. The CSR must be signed with the corresponding private key.',
      400,
    );
  }

  // ---- 4a. Verify deviceId matches SHA-256(SPKI) from CSR -----------------
  // The deviceId must be the hex-encoded SHA-256 hash of the CSR's
  // SubjectPublicKeyInfo DER bytes. This binds the deviceId to the hardware
  // key, preventing an attacker from claiming an arbitrary deviceId.
  {
    const spkiHashBuffer = await crypto.subtle.digest('SHA-256', csrData.publicKeyDer);
    const expectedDeviceId = Array.from(new Uint8Array(spkiHashBuffer))
      .map((b) => b.toString(16).padStart(2, '0'))
      .join('');
    if (body.deviceId !== expectedDeviceId) {
      return jsonError('deviceId does not match CSR public key', 403);
    }
  }


  // ---- 5. Validate device attestation --------------------------------------
  let attestationPublicKey: string | undefined;
  if (requireIntegrity === 'off') {
    console.log('[provision] Device integrity enforcement is off, skipping attestation');
  } else try {
    if (body.platform === 'ios') {
      const result = await validateAppleAttestation({
        attestation: body.attestation,
        challenge: body.challenge,
        appId: env.APPLE_APP_ID,
        teamId: env.APPLE_TEAM_ID,
      });

      if (!result.valid) {
        return jsonError('Apple attestation failed', 403);
      }

      attestationPublicKey = result.publicKey;
    } else {
      // Parse certificate digests from env
      const expectedDigests = env.ANDROID_CERTIFICATE_DIGESTS
        ? env.ANDROID_CERTIFICATE_DIGESTS.split(',').map((d) => d.trim())
        : [];

      const result = await validatePlayIntegrity({
        token: body.attestation,
        serviceAccountEmail: env.FCM_SERVICE_ACCOUNT_EMAIL,
        serviceAccountKey: env.FCM_SERVICE_ACCOUNT_KEY,
        expectedPackageName: env.ANDROID_PACKAGE_NAME,
        expectedNonce: body.challenge,
        expectedCertificateDigests: expectedDigests,
        allowSideloadedWithoutDigest: env.ALLOW_SIDELOADED === 'true',
        requireDeviceIntegrity: env.REQUIRE_DEVICE_INTEGRITY,
      });

      if (!result.valid) {
        return jsonError(`Android attestation failed: ${result.error}`, 403);
      }

      // Google Play Integrity doesn't return a credential public key,
      // so we can't do attestation-CSR binding for Android via Play Integrity alone.
      // However, Android Key Attestation (if provided) bridges this gap
      // by proving the CSR's public key was generated in hardware.
    }
  } catch (error) {
    console.error('Attestation validation threw:', error);
    return jsonError('Device attestation verification error', 500);
  }

  // ---- 5a. Mandatory Key Attestation enforcement ---------------------------
  // When REQUIRE_KEY_ATTESTATION is "on" or "log", enforce that Android devices
  // provide a Key Attestation chain proving the CSR key is hardware-backed.
  const requireKeyAttestation = (env.REQUIRE_KEY_ATTESTATION ?? 'off').toLowerCase();
  if (!['off', 'log', 'on'].includes(requireKeyAttestation)) {
    console.error(`[provision] Invalid REQUIRE_KEY_ATTESTATION value: "${requireKeyAttestation}", defaulting to "off"`);
  }

  if (body.platform === 'android') {
    if (!body.keyAttestationChain?.length) {
      if (requireKeyAttestation === 'on') {
        return jsonError('Key Attestation chain required for Android provisioning', 403);
      } else if (requireKeyAttestation === 'log') {
        console.warn('[provision] WARN: No Key Attestation chain provided (log mode)');
      }
    }
  }

  // ---- 5b. Android Key Attestation validation (hardware key binding) ------
  // Verifies the CSR's public key was generated in TEE/StrongBox on this device.
  // This is additive — Play Integrity is still required above.
  // Key Attestation bridges the gap where Play Integrity proves "real device"
  // but not "this specific key was generated on this device's hardware."
  if (body.platform === 'android' && body.keyAttestationChain?.length) {
    try {
      const { validateKeyAttestation } = await import('../validation/key_attestation');
      const keyAttResult = await validateKeyAttestation({
        certChain: body.keyAttestationChain,
        expectedChallenge: body.challenge,
      });

      if (!keyAttResult.valid) {
        return jsonError(`Key attestation failed: ${keyAttResult.error}`, 403);
      }

      // Compare attested public key with CSR's public key (SHA-256 of SPKI DER).
      // This ensures the key proven to be in hardware is the same key in the CSR.
      if (keyAttResult.publicKeyDer) {
        const attPubKeyHash = await sha256hex(keyAttResult.publicKeyDer);
        if (attPubKeyHash !== body.deviceId) {
          return jsonError('CSR public key does not match attested hardware key', 403);
        }
        console.log('[provision] Android Key Attestation verified: hardware key matches CSR');
      }
    } catch (error) {
      console.error('[provision] Key attestation validation error:', error);
      return jsonError('Key attestation verification error', 500);
    }
  }

  // ---- 6. Bind attestation to CSR (where possible) -------------------------
  // For iOS: verify that the attestation credential public key matches
  // the CSR's public key (prevents attacker from swapping CSR).
  if (attestationPublicKey && body.platform === 'ios') {
    const csrPublicKeyBase64 = uint8ArrayToBase64(csrData.publicKeyDer);

    // The attestation public key is the raw SPKI from the leaf cert.
    // Compare with the CSR's SPKI.
    if (attestationPublicKey !== csrPublicKeyBase64) {
      console.error(
        'Attestation-CSR binding failed: public keys do not match',
      );
      return jsonError(
        'Attestation credential public key does not match CSR public key',
        403,
      );
    }
  }

  // ---- 7. Sign CSR with CA -------------------------------------------------
  let signedCert: string | null;
  try {
    signedCert = await signCSR({
      csr: body.csr,
      caPrivateKey: env.CA_PRIVATE_KEY,
      caCertificate: env.CA_CERTIFICATE,
      deviceId: body.deviceId,
      validityDays: CERTIFICATE_VALIDITY_DAYS,
    });
  } catch (error) {
    console.error('CSR signing failed:', error);
    return jsonError('Certificate signing failed', 500);
  }

  if (!signedCert) {
    return jsonError('Certificate signing produced no output', 500);
  }

  // ---- 8. Register cert with Cloudflare Access (optional) ------------------
  // CF Access mTLS is not currently used — the relay authenticates devices via
  // cert:{fingerprint} KV lookup (step 8a below). This registration is kept
  // for future use but is non-fatal.
  const certName = `device-${body.deviceId}`;
  try {
    const registered = await registerCertWithAccess({
      accountId: env.CF_ACCOUNT_ID,
      clientId: env.CF_ACCESS_CLIENT_ID,
      clientSecret: env.CF_ACCESS_CLIENT_SECRET,
      certificate: signedCert,
      name: certName,
    });
    if (!registered) {
      console.warn('[provision] CF Access cert registration failed (non-fatal)');
    }
  } catch (error) {
    console.warn('[provision] CF Access registration error (non-fatal):', error);
  }

  // ---- 8a. Write cert fingerprint to KV (for relay device auth) ------------
  // The relay reads `cert:{fingerprint}` to verify connecting devices.
  // PROVISION_KV and PROVISIONED_DEVICES share the same KV namespace in prod.
  try {
    const certDer = pemToDer(signedCert);
    console.log(`[provision] cert DER length: ${certDer.length}`);
    const hashBuffer = await crypto.subtle.digest('SHA-256', certDer);
    const fingerprint = Array.from(new Uint8Array(hashBuffer))
      .map((b) => b.toString(16).padStart(2, '0'))
      .join('');
    console.log(`[provision] cert fingerprint: ${fingerprint}`);

    await env.PROVISION_KV.put(
      `cert:${fingerprint}`,
      JSON.stringify({
        deviceId: body.deviceId,
        platform: body.platform,
        provisionedAt: new Date().toISOString(),
      }),
      { expirationTtl: 54 * 60 * 60 }, // 48h cert validity + 6h buffer
    );
    console.log(`[provision] Wrote cert:${fingerprint} to KV`);
  } catch (error) {
    // Non-fatal: cert is valid, but relay auth may fail until manually fixed
    console.error('Failed to write cert fingerprint to KV:', error);
  }


  // ---- 9b. Record device provisioning in KV --------------------------------
  await env.PROVISION_KV.put(
    deviceProvisionKey,
    JSON.stringify({
      platform: body.platform,
      provisionedAt: new Date().toISOString(),
    }),
    { expirationTtl: deviceCooldownSeconds },
  );

  // ---- 10. Build and return response ----------------------------------------
  const expiresAt = new Date();
  expiresAt.setDate(expiresAt.getDate() + CERTIFICATE_VALIDITY_DAYS);

  const response: ProvisionResponse = {
    certificate: signedCert,
    expiresAt: expiresAt.toISOString(),
  };

  return new Response(JSON.stringify(response), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function jsonError(message: string, status: number): Response {
  return new Response(
    JSON.stringify({ error: message }),
    {
      status,
      headers: { 'Content-Type': 'application/json' },
    },
  );
}

function uint8ArrayToBase64(bytes: Uint8Array): string {
  let binaryString = '';
  for (let i = 0; i < bytes.length; i++) {
    binaryString += String.fromCharCode(bytes[i]);
  }
  return btoa(binaryString);
}

function pemToDer(pem: string): Uint8Array {
  const base64 = pem
    .replace(/-----BEGIN [^-]+-----/g, '')
    .replace(/-----END [^-]+-----/g, '')
    .replace(/\s/g, '');
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

/**
 * Compute SHA-256 hash of the given bytes and return as lowercase hex string.
 */
async function sha256hex(data: Uint8Array): Promise<string> {
  const hashBuffer = await crypto.subtle.digest('SHA-256', data);
  return Array.from(new Uint8Array(hashBuffer))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

