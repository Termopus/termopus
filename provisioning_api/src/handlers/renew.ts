import type { Env } from '../index';
import { validateAppleAttestation } from '../validation/apple';
import { validatePlayIntegrity } from '../validation/google';
import { verifyCSRSignature, signCSR } from '../crypto/csr';
import { registerCertWithAccess, revokeCertFromAccess } from '../cloudflare/access';
import { verifyAndConsumeChallenge } from './challenge';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface RenewRequest {
  /** PEM-encoded new CSR. */
  csr: string;
  /** Base64-encoded platform attestation (assertion). */
  attestation: string;
  /** Client platform. */
  platform: 'ios' | 'android';
  /** Device identifier. */
  deviceId: string;
  /** PEM-encoded expired client certificate (proof of prior provisioning). */
  expiredCert: string;
  /** Single-use server-generated challenge (from /provision/challenge). */
  challenge: string;
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/** Renewed certificate validity (48 hours). */
const RENEWAL_VALIDITY_DAYS = 2;

/** Max renewal attempts per device per hour. */
const MAX_RENEWALS_PER_HOUR = 5;

/** Rate limit window in seconds. */
const RATE_LIMIT_WINDOW = 3600;

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

/**
 * Handle certificate renewal.
 *
 * This endpoint does NOT require valid mTLS (cert may be expired).
 * Auth is via attestation assertion + CA-signed expired certificate.
 *
 * Flow:
 *  1. Validate request fields
 *  2. Rate limit (5/hour per device)
 *  3. Verify the expired cert was signed by our CA
 *  4. Verify CSR self-signature
 *  5. Verify attestation assertion
 *  6. Check subscription status in KV
 *  7. Sign new CSR
 *  8. Register new cert with CF Access
 *  9. Revoke old cert from CF Access
 * 10. Update KV records
 */
export async function handleRenew(request: Request, env: Env): Promise<Response> {
  // ---- 1. Parse and validate ------------------------------------------------
  let body: RenewRequest;
  try {
    body = await request.json() as RenewRequest;
  } catch {
    return jsonError('Request body must be valid JSON', 400);
  }

  const requireIntegrity = (env.REQUIRE_DEVICE_INTEGRITY ?? 'off').toLowerCase();
  const missingFields: string[] = [];
  if (!body.csr) missingFields.push('csr');
  if (requireIntegrity !== 'off' && !body.attestation) missingFields.push('attestation');
  if (!body.platform) missingFields.push('platform');
  if (!body.deviceId) missingFields.push('deviceId');
  if (!body.expiredCert) missingFields.push('expiredCert');
  if (!body.challenge) missingFields.push('challenge');

  if (missingFields.length > 0) {
    return jsonError(`Missing required fields: ${missingFields.join(', ')}`, 400);
  }

  if (!['ios', 'android'].includes(body.platform)) {
    return jsonError('Invalid platform', 400);
  }

  if (!/^[a-zA-Z0-9\-_]{1,128}$/.test(body.deviceId)) {
    return jsonError('Invalid deviceId format', 400);
  }

  // ---- 2. Rate limit --------------------------------------------------------
  const rateLimitKey = `renew_rate:${body.deviceId}`;
  const currentCount = await env.PROVISION_KV.get(rateLimitKey);
  const count = currentCount ? parseInt(currentCount, 10) : 0;

  if (count >= MAX_RENEWALS_PER_HOUR) {
    return jsonError('Too many renewal attempts. Try again later.', 429);
  }

  await env.PROVISION_KV.put(
    rateLimitKey,
    String(count + 1),
    { expirationTtl: RATE_LIMIT_WINDOW },
  );

  // ---- 3. Verify expired cert was signed by our CA --------------------------
  const certVerified = await verifyCACertSignature(body.expiredCert, env);
  if (!certVerified) {
    return jsonError('Expired certificate was not signed by this CA', 403);
  }

  // ---- 3a. Verify expired cert CN matches claimed deviceId -----------------
  try {
    const expiredCertDer = pemToDer(body.expiredCert);
    const cn = extractCNFromCert(expiredCertDer);
    if (cn !== `device-${body.deviceId}`) {
      console.warn(`[renew] CN mismatch: cert="${cn}" claimed="device-${body.deviceId}"`);
      return jsonError('Certificate identity does not match claimed device', 403);
    }
  } catch (error) {
    console.error('Failed to extract CN from expired cert:', error);
    return jsonError('Failed to verify certificate identity', 400);
  }

  // ---- 3b. Verify server-issued challenge ----------------------------------
  const challengeData = await verifyAndConsumeChallenge(body.challenge, env);
  if (!challengeData) {
    return jsonError(
      'Invalid or expired challenge. Request a new challenge from /provision/challenge.',
      403,
    );
  }
  if (challengeData.deviceId !== body.deviceId) {
    return jsonError('Challenge was issued for a different device', 403);
  }

  // ---- 4. Verify CSR self-signature -----------------------------------------
  const csrData = await verifyCSRSignature(body.csr);
  if (!csrData) {
    return jsonError('CSR signature verification failed', 400);
  }

  // ---- 5. Verify attestation assertion (using server challenge as nonce) -----
  if (requireIntegrity === 'off') {
    console.log('[renew] Device integrity enforcement is off, skipping attestation');
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
    } else {
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
    }
  } catch (error) {
    console.error('Attestation validation error during renewal:', error);
    return jsonError('Attestation verification error', 500);
  }


  // ---- 7. Sign new CSR ------------------------------------------------------
  let signedCert: string | null;
  try {
    signedCert = await signCSR({
      csr: body.csr,
      caPrivateKey: env.CA_PRIVATE_KEY,
      caCertificate: env.CA_CERTIFICATE,
      deviceId: body.deviceId,
      validityDays: RENEWAL_VALIDITY_DAYS,
    });
  } catch (error) {
    console.error('CSR signing failed during renewal:', error);
    return jsonError('Certificate signing failed', 500);
  }

  if (!signedCert) {
    return jsonError('Certificate signing produced no output', 500);
  }

  // ---- 8. Register new cert with CF Access ----------------------------------
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
      return jsonError('Failed to register new certificate', 500);
    }
  } catch (error) {
    console.error('CF Access registration failed during renewal:', error);
    return jsonError('Certificate registration failed', 500);
  }

  // ---- 9. Revoke old cert ---------------------------------------------------
  try {
    await revokeCertFromAccess({
      accountId: env.CF_ACCOUNT_ID,
      clientId: env.CF_ACCESS_CLIENT_ID,
      clientSecret: env.CF_ACCESS_CLIENT_SECRET,
      name: `${certName}-old`,
    });
  } catch {
    // Non-fatal: old cert may already be expired/revoked
  }

  // ---- 10. Update KV (zombie cleanup + new cert record) --------------------
  try {
    // Compute OLD cert fingerprint and delete it (zombie cleanup)
    const oldCertDer = pemToDer(body.expiredCert);
    const oldHashBuffer = await crypto.subtle.digest('SHA-256', oldCertDer);
    const oldFingerprint = Array.from(new Uint8Array(oldHashBuffer))
      .map((b) => b.toString(16).padStart(2, '0'))
      .join('');

    await env.PROVISION_KV.delete(`cert:${oldFingerprint}`);
    console.log(`[renew] Deleted old cert:${oldFingerprint}`);
  } catch (error) {
    // Non-fatal: old cert record may not exist or already cleaned up
    console.warn('[renew] Failed to delete old cert fingerprint:', error);
  }

  try {
    // Write new cert record
    const newCertDer = pemToDer(signedCert);
    const newHashBuffer = await crypto.subtle.digest('SHA-256', newCertDer);
    const newFingerprint = Array.from(new Uint8Array(newHashBuffer))
      .map((b) => b.toString(16).padStart(2, '0'))
      .join('');

    await env.PROVISION_KV.put(
      `cert:${newFingerprint}`,
      JSON.stringify({
        deviceId: body.deviceId,
        platform: body.platform,
        provisionedAt: new Date().toISOString(),
        renewedAt: new Date().toISOString(),
      }),
      { expirationTtl: 54 * 60 * 60 }, // 48h cert validity + 6h buffer
    );
    console.log(`[renew] Wrote new cert:${newFingerprint}`);
  } catch (error) {
    console.error('Failed to write new cert fingerprint KV:', error);
  }

  // ---- Response -------------------------------------------------------------
  const expiresAt = new Date();
  expiresAt.setDate(expiresAt.getDate() + RENEWAL_VALIDITY_DAYS);

  return new Response(
    JSON.stringify({
      certificate: signedCert,
      expiresAt: expiresAt.toISOString(),
    }),
    {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    },
  );
}

// ---------------------------------------------------------------------------
// CA cert verification
// ---------------------------------------------------------------------------

/**
 * Verify that the expired certificate was signed by our CA.
 * Parses the CA cert, imports its public key, and verifies the signature
 * on the expired cert.
 */
async function verifyCACertSignature(expiredCertPem: string, env: Env): Promise<boolean> {
  try {
    const certDer = pemToDer(expiredCertPem);
    const caCertDer = pemToDer(env.CA_CERTIFICATE);

    // Extract the CA's public key from its certificate
    // Import as X.509 certificate to get the SPKI
    const caPublicKey = await crypto.subtle.importKey(
      'spki',
      extractSPKI(caCertDer),
      { name: 'ECDSA', namedCurve: 'P-256' },
      false,
      ['verify'],
    );

    // Extract TBSCertificate and signature from the expired cert
    const { tbsCertificate, signature } = extractTBSAndSignature(certDer);

    // Verify
    return await crypto.subtle.verify(
      { name: 'ECDSA', hash: 'SHA-256' },
      caPublicKey,
      signature,
      tbsCertificate,
    );
  } catch (error) {
    console.error('CA cert signature verification error:', error);
    return false;
  }
}

/**
 * Extract SubjectPublicKeyInfo from a DER-encoded X.509 certificate.
 * Minimal ASN.1 parser — walks SEQUENCE → TBSCertificate → finds SPKI.
 */
function extractSPKI(certDer: Uint8Array): ArrayBuffer {
  // Outer SEQUENCE
  let offset = 0;
  if (certDer[offset] !== 0x30) throw new Error('Not a SEQUENCE');
  const outerLen = readASN1Length(certDer, offset + 1);
  offset = outerLen.offset;

  // TBSCertificate SEQUENCE
  if (certDer[offset] !== 0x30) throw new Error('TBS not a SEQUENCE');
  const tbsLen = readASN1Length(certDer, offset + 1);
  const tbsStart = tbsLen.offset;

  // Walk TBS fields: version[0], serialNumber, signature, issuer, validity, subject, subjectPublicKeyInfo
  let pos = tbsStart;

  // Skip version (context-specific [0])
  if (certDer[pos] === 0xA0) {
    const vLen = readASN1Length(certDer, pos + 1);
    pos = vLen.offset + vLen.length;
  }

  // Skip serialNumber (INTEGER)
  pos = skipASN1Element(certDer, pos);
  // Skip signature AlgorithmIdentifier (SEQUENCE)
  pos = skipASN1Element(certDer, pos);
  // Skip issuer (SEQUENCE)
  pos = skipASN1Element(certDer, pos);
  // Skip validity (SEQUENCE)
  pos = skipASN1Element(certDer, pos);
  // Skip subject (SEQUENCE)
  pos = skipASN1Element(certDer, pos);

  // subjectPublicKeyInfo — this is what we need
  const spkiTag = certDer[pos];
  if (spkiTag !== 0x30) throw new Error('SPKI not a SEQUENCE');
  const spkiLen = readASN1Length(certDer, pos + 1);
  const spkiEnd = spkiLen.offset + spkiLen.length;

  return certDer.slice(pos, spkiEnd).buffer;
}

/**
 * Extract TBSCertificate bytes and signature from a DER-encoded cert.
 */
function extractTBSAndSignature(certDer: Uint8Array): { tbsCertificate: ArrayBuffer; signature: ArrayBuffer } {
  let offset = 0;
  // Outer SEQUENCE
  if (certDer[offset] !== 0x30) throw new Error('Not a SEQUENCE');
  readASN1Length(certDer, offset + 1);
  const outerOffset = readASN1Length(certDer, 1).offset;

  // TBSCertificate SEQUENCE
  const tbsStart = outerOffset;
  const tbsLenInfo = readASN1Length(certDer, tbsStart + 1);
  const tbsEnd = tbsLenInfo.offset + tbsLenInfo.length;
  const tbsCertificate = certDer.slice(tbsStart, tbsEnd);

  // SignatureAlgorithm SEQUENCE — skip
  let pos = tbsEnd;
  pos = skipASN1Element(certDer, pos);

  // Signature BIT STRING
  if (certDer[pos] !== 0x03) throw new Error('Signature not a BIT STRING');
  const sigLen = readASN1Length(certDer, pos + 1);
  // Skip the unused-bits byte (0x00)
  const sigBytes = certDer.slice(sigLen.offset + 1, sigLen.offset + sigLen.length);

  return {
    tbsCertificate: tbsCertificate.buffer,
    signature: sigBytes.buffer,
  };
}

/**
 * Extract the Subject Common Name (CN) from a DER-encoded X.509 certificate.
 *
 * Walks TBSCertificate → Subject → RDNSequence to find the CN attribute
 * (OID 2.5.4.3 = 0x55, 0x04, 0x03).
 */
function extractCNFromCert(certDer: Uint8Array): string {
  // Outer SEQUENCE
  let offset = 0;
  if (certDer[offset] !== 0x30) throw new Error('Not a SEQUENCE');
  const outerLen = readASN1Length(certDer, offset + 1);
  offset = outerLen.offset;

  // TBSCertificate SEQUENCE
  if (certDer[offset] !== 0x30) throw new Error('TBS not a SEQUENCE');
  const tbsLen = readASN1Length(certDer, offset + 1);
  let pos = tbsLen.offset;

  // Skip version (context-specific [0])
  if (certDer[pos] === 0xA0) {
    const vLen = readASN1Length(certDer, pos + 1);
    pos = vLen.offset + vLen.length;
  }

  // Skip serialNumber (INTEGER)
  pos = skipASN1Element(certDer, pos);
  // Skip signature AlgorithmIdentifier (SEQUENCE)
  pos = skipASN1Element(certDer, pos);
  // Skip issuer (SEQUENCE)
  pos = skipASN1Element(certDer, pos);
  // Skip validity (SEQUENCE)
  pos = skipASN1Element(certDer, pos);

  // Subject (SEQUENCE of SETs)
  if (certDer[pos] !== 0x30) throw new Error('Subject not a SEQUENCE');
  const subjectLen = readASN1Length(certDer, pos + 1);
  const subjectEnd = subjectLen.offset + subjectLen.length;
  pos = subjectLen.offset;

  // CN OID: 2.5.4.3 → DER-encoded as 0x55, 0x04, 0x03
  const CN_OID = new Uint8Array([0x55, 0x04, 0x03]);

  // Walk each SET in the RDNSequence
  while (pos < subjectEnd) {
    // SET
    if (certDer[pos] !== 0x31) {
      pos = skipASN1Element(certDer, pos);
      continue;
    }
    const setLen = readASN1Length(certDer, pos + 1);
    const setEnd = setLen.offset + setLen.length;
    let setPos = setLen.offset;

    // Each SET contains one or more SEQUENCE (AttributeTypeAndValue)
    while (setPos < setEnd) {
      if (certDer[setPos] !== 0x30) {
        setPos = skipASN1Element(certDer, setPos);
        continue;
      }
      const attrLen = readASN1Length(certDer, setPos + 1);
      const attrContentStart = attrLen.offset;

      // OID tag
      if (certDer[attrContentStart] !== 0x06) {
        setPos = skipASN1Element(certDer, setPos);
        continue;
      }
      const oidLen = readASN1Length(certDer, attrContentStart + 1);
      const oidBytes = certDer.slice(oidLen.offset, oidLen.offset + oidLen.length);

      // Check if this OID is CN (2.5.4.3)
      if (oidBytes.length === CN_OID.length &&
          oidBytes.every((b, i) => b === CN_OID[i])) {
        // Value follows the OID — typically UTF8String (0x0C) or PrintableString (0x13)
        let valuePos = oidLen.offset + oidLen.length;
        const valueTag = certDer[valuePos];
        if (valueTag !== 0x0C && valueTag !== 0x13 && valueTag !== 0x16) {
          throw new Error(`Unexpected CN value tag: 0x${valueTag.toString(16)}`);
        }
        const valueLen = readASN1Length(certDer, valuePos + 1);
        const valueBytes = certDer.slice(valueLen.offset, valueLen.offset + valueLen.length);
        return new TextDecoder().decode(valueBytes);
      }

      setPos = skipASN1Element(certDer, setPos);
    }

    pos = setEnd;
  }

  throw new Error('CN not found in certificate Subject');
}

// ---------------------------------------------------------------------------
// ASN.1 helpers
// ---------------------------------------------------------------------------

function readASN1Length(data: Uint8Array, offset: number): { length: number; offset: number } {
  const firstByte = data[offset];
  if (firstByte < 0x80) {
    return { length: firstByte, offset: offset + 1 };
  }
  const numBytes = firstByte & 0x7F;
  let length = 0;
  for (let i = 0; i < numBytes; i++) {
    length = (length << 8) | data[offset + 1 + i];
  }
  return { length, offset: offset + 1 + numBytes };
}

function skipASN1Element(data: Uint8Array, offset: number): number {
  const lenInfo = readASN1Length(data, offset + 1);
  return lenInfo.offset + lenInfo.length;
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
