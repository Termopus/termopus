// ---------------------------------------------------------------------------
// Apple App Attest Validation
//
// Validates attestation objects produced by Apple's DeviceCheck / App Attest
// framework.  The attestation proves that the request originates from a
// genuine, un-jailbroken Apple device running the expected app bundle.
//
// Reference:
//   https://developer.apple.com/documentation/devicecheck/validating_apps_that_connect_to_your_server
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface AppleAttestationParams {
  /** Base64-encoded CBOR attestation object from the client. */
  attestation: string;
  /** The challenge string that was sent to the device before attestation. */
  challenge: string;
  /** Expected app bundle identifier (e.g. "app.clauderemote"). */
  appId: string;
  /** Apple Developer Team ID. */
  teamId: string;
}

/**
 * Result of attestation validation, including credential data for storage.
 */
export interface AppleAttestationResult {
  /** Whether the attestation is valid. */
  valid: boolean;
  /** Base64-encoded credential ID (for future assertion verification). */
  credentialId?: string;
  /** Initial sign count (should be 0 for attestation). */
  signCount?: number;
  /** Base64-encoded SPKI (SubjectPublicKeyInfo) from the leaf certificate. */
  publicKey?: string;
}

/**
 * Decoded structure of the CBOR attestation object.
 *
 * The object follows the WebAuthn attestation format:
 *   https://www.w3.org/TR/webauthn-2/#sctn-attestation
 */
interface AttestationObject {
  /** Attestation format — must be "apple-appattest". */
  fmt: string;
  /** Attestation statement containing the certificate chain and receipt. */
  attStmt: {
    /** X.509 certificate chain, leaf first. DER-encoded. */
    x5c: Uint8Array[];
    /** Opaque receipt for follow-up assertion validation. */
    receipt: Uint8Array;
  };
  /** Raw authenticator data (CBOR-encoded). */
  authData: Uint8Array;
}

/**
 * Parsed authenticator data embedded in the attestation.
 *
 * Layout (per WebAuthn spec):
 *   - rpIdHash    (32 bytes): SHA-256 of the relying party identifier
 *   - flags       (1 byte):   bit field
 *   - signCount   (4 bytes):  big-endian uint32
 *   - aaguid      (16 bytes): attestation GUID
 *   - credIdLen   (2 bytes):  big-endian uint16
 *   - credId      (credIdLen bytes)
 *   - ...extensions
 */
interface AuthenticatorData {
  rpIdHash: Uint8Array;
  flags: number;
  signCount: number;
  aaguid: Uint8Array;
  credentialId: Uint8Array;
}

// ---------------------------------------------------------------------------
// Apple App Attest root certificate (DER, base64)
// ---------------------------------------------------------------------------

// Apple App Attest Root CA — used to anchor the certificate chain.
// Subject: CN=Apple App Attestation Root CA, O=Apple Inc., ST=California
const APPLE_APP_ATTEST_ROOT_CA_BASE64 =
  'MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw' +
  'JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK' +
  'QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa' +
  'Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv' +
  'biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y' +
  'bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh' +
  'NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au' +
  'Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/' +
  'MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw' +
  'CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn' +
  '53O5+FRXgeLhd2ySgo1N3eFnAjEAp5U4xDgEgllF7EN3fmN9GKCDalvYobuNcEyW' +
  'JHgT+sTUQLVVpOBNAtx1pw9O';

// OID 1.2.840.113635.100.8.2 — Apple App Attest nonce extension
const APPLE_ATTEST_NONCE_OID = '1.2.840.113635.100.8.2';
const APPLE_ATTEST_NONCE_OID_BYTES = new Uint8Array([
  0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x08, 0x02,
]);

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Validate an Apple App Attest attestation object.
 *
 * Steps:
 *  1. Decode the base64 attestation into a CBOR attestation object.
 *  2. Verify the X.509 certificate chain anchors to the Apple root CA.
 *  3. Extract the authenticator data and verify the nonce matches
 *     SHA-256(authData || SHA-256(challenge)).
 *  4. Verify the RP ID hash matches SHA-256(teamId + "." + appId).
 *
 * Returns attestation result with credential ID and sign count.
 */
export async function validateAppleAttestation(
  params: AppleAttestationParams,
): Promise<AppleAttestationResult> {
  try {
    // ---- 1. Decode attestation ---------------------------------------------
    const rawBytes = base64ToUint8Array(params.attestation);
    const attestationObj = decodeCBORAttestationObject(rawBytes);

    if (!attestationObj) {
      console.error('Failed to decode CBOR attestation object');
      return { valid: false };
    }

    // ---- 2. Verify format ---------------------------------------------------
    if (attestationObj.fmt !== 'apple-appattest') {
      console.error(`Unexpected attestation format: ${attestationObj.fmt}`);
      return { valid: false };
    }

    // ---- 3. Verify certificate chain ----------------------------------------
    if (!attestationObj.attStmt.x5c || attestationObj.attStmt.x5c.length < 2) {
      console.error('Certificate chain too short');
      return { valid: false };
    }

    const chainValid = await verifyCertificateChain(attestationObj.attStmt.x5c);
    if (!chainValid) {
      console.error('Certificate chain verification failed');
      return { valid: false };
    }

    // ---- 4. Parse authenticator data ----------------------------------------
    const authData = parseAuthenticatorData(attestationObj.authData);
    if (!authData) {
      console.error('Failed to parse authenticator data');
      return { valid: false };
    }

    // ---- 5. Verify nonce (compositeHash vs leaf certificate extension) ------
    // Compute clientDataHash = SHA-256(challenge)
    const clientDataHash = await sha256(new TextEncoder().encode(params.challenge));

    // Compute compositeHash = SHA-256(authData || clientDataHash)
    const compositePayload = concatUint8Arrays(attestationObj.authData, clientDataHash);
    const compositeHash = await sha256(compositePayload);

    // Extract nonce from leaf certificate extension OID 1.2.840.113635.100.8.2
    const leafCertDer = attestationObj.attStmt.x5c[0];
    const extractedNonce = extractNonceFromCertificate(leafCertDer);

    if (!extractedNonce) {
      console.error('Failed to extract nonce from leaf certificate');
      return { valid: false };
    }

    if (!uint8ArrayEquals(extractedNonce, compositeHash)) {
      console.error('Nonce mismatch: compositeHash does not match certificate extension nonce');
      return { valid: false };
    }

    // ---- 6. Verify RP ID hash -----------------------------------------------
    const expectedRpId = `${params.teamId}.${params.appId}`;
    const expectedRpIdHash = await sha256(new TextEncoder().encode(expectedRpId));

    if (!uint8ArrayEquals(authData.rpIdHash, expectedRpIdHash)) {
      console.error('RP ID hash mismatch');
      return { valid: false };
    }

    // ---- 7. Verify sign count -----------------------------------------------
    // For attestation (first request), signCount should be 0.
    if (authData.signCount !== 0) {
      console.error(`Unexpected sign count for attestation: ${authData.signCount}`);
      return { valid: false };
    }

    // Extract SPKI from leaf cert for CSR binding comparison
    const leafSpki = extractSPKIFromCert(leafCertDer);
    if (!leafSpki) {
      console.error('Failed to extract SPKI from attestation leaf certificate');
      return { valid: false };
    }

    console.log('Apple attestation validated successfully');
    return {
      valid: true,
      credentialId: uint8ArrayToBase64(authData.credentialId),
      signCount: authData.signCount,
      publicKey: uint8ArrayToBase64(leafSpki),
    };
  } catch (error) {
    console.error('Apple attestation validation error:', error);
    return { valid: false };
  }
}

// ---------------------------------------------------------------------------
// Assertion Verification
// ---------------------------------------------------------------------------

export interface AppleAssertionParams {
  /** Base64-encoded CBOR assertion object from the client. */
  assertion: string;
  /** The challenge string that was sent to the device before assertion. */
  challenge: string;
  /** Base64-encoded leaf certificate DER (stored from attestation). */
  credentialPublicKey: string;
  /** Expected sign count (must be > previous count). */
  previousSignCount: number;
  /** Expected app bundle identifier. */
  appId: string;
  /** Apple Developer Team ID. */
  teamId: string;
}

export interface AppleAssertionResult {
  valid: boolean;
  newSignCount?: number;
}

/**
 * Validate an Apple App Attest assertion.
 *
 * Verifies the assertion signature using the stored credential public key
 * and checks that the sign counter is monotonically increasing.
 */
export async function validateAppleAssertion(
  params: AppleAssertionParams,
): Promise<AppleAssertionResult> {
  try {
    const rawBytes = base64ToUint8Array(params.assertion);
    const assertionObj = decodeCBORAssertionObject(rawBytes);
    if (!assertionObj) {
      console.error('Failed to decode CBOR assertion object');
      return { valid: false };
    }

    // Parse authenticator data from assertion
    const authData = parseAuthenticatorData(assertionObj.authenticatorData);
    if (!authData) {
      console.error('Failed to parse assertion authenticator data');
      return { valid: false };
    }

    // Verify RP ID hash
    const expectedRpId = `${params.teamId}.${params.appId}`;
    const expectedRpIdHash = await sha256(new TextEncoder().encode(expectedRpId));
    if (!uint8ArrayEquals(authData.rpIdHash, expectedRpIdHash)) {
      console.error('Assertion RP ID hash mismatch');
      return { valid: false };
    }

    // Verify sign count is increasing
    if (authData.signCount <= params.previousSignCount) {
      console.error(
        `Sign count not increasing: got ${authData.signCount}, expected > ${params.previousSignCount}`,
      );
      return { valid: false };
    }

    // Compute clientDataHash = SHA-256(challenge)
    const clientDataHash = await sha256(new TextEncoder().encode(params.challenge));

    // Verify signature: signature is over (authenticatorData || clientDataHash)
    const signedData = concatUint8Arrays(assertionObj.authenticatorData, clientDataHash);

    // Import the credential public key from the stored leaf certificate
    const certDer = base64ToUint8Array(params.credentialPublicKey);
    const publicKey = await importECPublicKeyFromCertificate(certDer);
    if (!publicKey) {
      console.error('Failed to import credential public key');
      return { valid: false };
    }

    // Verify the ECDSA signature
    const signatureValid = await crypto.subtle.verify(
      { name: 'ECDSA', hash: { name: 'SHA-256' } },
      publicKey,
      assertionObj.signature,
      signedData,
    );

    if (!signatureValid) {
      console.error('Assertion signature verification failed');
      return { valid: false };
    }

    return {
      valid: true,
      newSignCount: authData.signCount,
    };
  } catch (error) {
    console.error('Apple assertion validation error:', error);
    return { valid: false };
  }
}

interface AssertionObject {
  authenticatorData: Uint8Array;
  signature: Uint8Array;
}

function decodeCBORAssertionObject(data: Uint8Array): AssertionObject | null {
  try {
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
    const result = decodeCBORValue(data, view, 0);
    if (!result || typeof result.value !== 'object' || result.value === null) {
      return null;
    }

    const map = result.value as Record<string, unknown>;
    const authenticatorData = map['authenticatorData'];
    const signature = map['signature'];

    if (!(authenticatorData instanceof Uint8Array) || !(signature instanceof Uint8Array)) {
      return null;
    }

    return { authenticatorData, signature };
  } catch (error) {
    console.error('CBOR assertion decode error:', error);
    return null;
  }
}

// ---------------------------------------------------------------------------
// Certificate Extension Parsing (Nonce Extraction)
// ---------------------------------------------------------------------------

/**
 * Extract the nonce from a DER-encoded X.509 certificate.
 *
 * The nonce is stored in an extension with OID 1.2.840.113635.100.8.2.
 * The extension value is an ASN.1 SEQUENCE containing an OCTET STRING
 * with the 32-byte nonce.
 */
function extractNonceFromCertificate(certDer: Uint8Array): Uint8Array | null {
  try {
    // Search for the Apple Attest nonce OID in the certificate DER
    const oidHex = Array.from(APPLE_ATTEST_NONCE_OID_BYTES)
      .map(b => b.toString(16).padStart(2, '0'))
      .join('');

    const certHex = Array.from(certDer)
      .map(b => b.toString(16).padStart(2, '0'))
      .join('');

    const oidIndex = certHex.indexOf(oidHex);
    if (oidIndex === -1) {
      console.error('Apple Attest nonce OID not found in certificate');
      return null;
    }

    // The OID is within an extension SEQUENCE. After the OID comes:
    // - possibly a BOOLEAN (critical flag)
    // - an OCTET STRING containing the extension value
    // The extension value itself is an ASN.1 structure containing the nonce.
    const oidByteOffset = oidIndex / 2;

    // Skip past the OID TLV
    const oidTag = parseASN1Tag(certDer, oidByteOffset - 2); // Back up to get the OID tag
    if (!oidTag) return null;

    let offset = oidByteOffset + APPLE_ATTEST_NONCE_OID_BYTES.length;

    // Check if next is BOOLEAN (critical flag) — skip if present
    if (offset < certDer.length && certDer[offset] === 0x01) {
      const boolTag = parseASN1Tag(certDer, offset);
      if (boolTag) offset = boolTag.contentOffset + boolTag.contentLength;
    }

    // Next should be OCTET STRING (extension value wrapper)
    if (offset >= certDer.length || certDer[offset] !== 0x04) {
      return null;
    }
    const octetTag = parseASN1Tag(certDer, offset);
    if (!octetTag) return null;
    offset = octetTag.contentOffset;

    // Inside the OCTET STRING is the extension value — parse it
    // Apple's nonce extension is: SEQUENCE { [1] EXPLICIT OCTET STRING(nonce) }
    // Walk through to find the 32-byte nonce
    const innerSeq = parseASN1Tag(certDer, offset);
    if (!innerSeq || innerSeq.tag !== 0x30) {
      // Try direct: the content might just be raw OCTET STRING with nonce
      if (octetTag.contentLength === 32) {
        return certDer.slice(offset, offset + 32);
      }
      return null;
    }

    // Walk the SEQUENCE looking for a 32-byte OCTET STRING
    let innerOffset = innerSeq.contentOffset;
    const innerEnd = innerSeq.contentOffset + innerSeq.contentLength;

    while (innerOffset < innerEnd) {
      const tag = parseASN1Tag(certDer, innerOffset);
      if (!tag) break;

      // Look for context-tagged or OCTET STRING containing 32 bytes
      if (tag.tag === 0x04 && tag.contentLength === 32) {
        return certDer.slice(tag.contentOffset, tag.contentOffset + 32);
      }

      // If it's a context tag (0xa1, etc.), look inside
      if ((tag.tag & 0xa0) === 0xa0) {
        const inner = parseASN1Tag(certDer, tag.contentOffset);
        if (inner && inner.tag === 0x04 && inner.contentLength === 32) {
          return certDer.slice(inner.contentOffset, inner.contentOffset + 32);
        }
      }

      innerOffset = tag.contentOffset + tag.contentLength;
    }

    return null;
  } catch (error) {
    console.error('Failed to extract nonce from certificate:', error);
    return null;
  }
}

// ---------------------------------------------------------------------------
// Certificate Key Import
// ---------------------------------------------------------------------------

/**
 * Import the EC public key from a DER-encoded X.509 certificate
 * for signature verification.
 */
async function importECPublicKeyFromCertificate(certDer: Uint8Array): Promise<CryptoKey | null> {
  try {
    const spki = extractSPKIFromCert(certDer);
    if (!spki) return null;

    return await crypto.subtle.importKey(
      'spki',
      spki.buffer as ArrayBuffer,
      { name: 'ECDSA', namedCurve: 'P-256' },
      true,
      ['verify'],
    );
  } catch (error) {
    console.error('Failed to import EC public key from certificate:', error);
    return null;
  }
}

function extractSPKIFromCert(certDer: Uint8Array): Uint8Array | null {
  try {
    let offset = 0;
    const certSeq = parseASN1Tag(certDer, offset);
    if (!certSeq || certSeq.tag !== 0x30) return null;

    offset = certSeq.contentOffset;
    const tbsSeq = parseASN1Tag(certDer, offset);
    if (!tbsSeq || tbsSeq.tag !== 0x30) return null;

    let fieldOffset = tbsSeq.contentOffset;

    // Skip version if present
    const firstField = parseASN1Tag(certDer, fieldOffset);
    if (firstField && firstField.tag === 0xa0) {
      fieldOffset = firstField.contentOffset + firstField.contentLength;
    }

    // Skip: serialNumber, signatureAlgorithm, issuer, validity, subject (5 fields)
    for (let i = 0; i < 5; i++) {
      const field = parseASN1Tag(certDer, fieldOffset);
      if (!field) return null;
      fieldOffset = field.contentOffset + field.contentLength;
    }

    // subjectPublicKeyInfo
    const spkiField = parseASN1Tag(certDer, fieldOffset);
    if (!spkiField || spkiField.tag !== 0x30) return null;

    return certDer.slice(fieldOffset, spkiField.contentOffset + spkiField.contentLength);
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// CBOR Decoding (minimal, attestation-specific)
// ---------------------------------------------------------------------------

/**
 * Minimal CBOR decoder that handles the attestation object structure.
 *
 * The attestation object is a CBOR map with three keys:
 *   - "fmt"     (text string)
 *   - "attStmt" (map with "x5c" array and "receipt" byte string)
 *   - "authData" (byte string)
 */
function decodeCBORAttestationObject(data: Uint8Array): AttestationObject | null {
  try {
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
    let offset = 0;

    const result = decodeCBORValue(data, view, offset);
    if (!result || typeof result.value !== 'object' || result.value === null) {
      return null;
    }

    const map = result.value as Record<string, unknown>;

    // Validate expected keys
    const fmt = map['fmt'];
    const attStmt = map['attStmt'] as Record<string, unknown> | undefined;
    const authData = map['authData'];

    if (typeof fmt !== 'string' || !attStmt || !(authData instanceof Uint8Array)) {
      return null;
    }

    // Parse x5c certificates from attStmt
    const x5cRaw = attStmt['x5c'];
    const receipt = attStmt['receipt'];

    if (!Array.isArray(x5cRaw) || !(receipt instanceof Uint8Array)) {
      return null;
    }

    const x5c = x5cRaw.map((cert: unknown) => {
      if (cert instanceof Uint8Array) return cert;
      return new Uint8Array(0);
    });

    return {
      fmt,
      attStmt: { x5c, receipt },
      authData: authData as Uint8Array,
    };
  } catch (error) {
    console.error('CBOR decode error:', error);
    return null;
  }
}

interface CBORDecodeResult {
  value: unknown;
  offset: number;
}

/**
 * Recursively decode a single CBOR value starting at `offset`.
 *
 * Supports: unsigned int, negative int, byte string, text string,
 * array, map, simple values (true/false/null).
 */
function decodeCBORValue(
  data: Uint8Array,
  view: DataView,
  offset: number,
): CBORDecodeResult | null {
  if (offset >= data.length) return null;

  const initialByte = data[offset];
  const majorType = initialByte >> 5;
  const additionalInfo = initialByte & 0x1f;
  offset++;

  // Decode the argument (length / value)
  let argument: number;
  if (additionalInfo < 24) {
    argument = additionalInfo;
  } else if (additionalInfo === 24) {
    argument = data[offset];
    offset++;
  } else if (additionalInfo === 25) {
    argument = view.getUint16(offset);
    offset += 2;
  } else if (additionalInfo === 26) {
    argument = view.getUint32(offset);
    offset += 4;
  } else if (additionalInfo === 27) {
    // 64-bit — read as Number (safe for lengths we'll encounter)
    const hi = view.getUint32(offset);
    const lo = view.getUint32(offset + 4);
    argument = hi * 0x100000000 + lo;
    offset += 8;
  } else if (additionalInfo === 31) {
    // Indefinite length — not used in attestation objects
    argument = -1;
  } else {
    return null; // Reserved
  }

  switch (majorType) {
    case 0: // Unsigned integer
      return { value: argument, offset };

    case 1: // Negative integer
      return { value: -(argument + 1), offset };

    case 2: // Byte string
      if (argument < 0) return null;
      return {
        value: data.slice(offset, offset + argument),
        offset: offset + argument,
      };

    case 3: // Text string
      if (argument < 0) return null;
      {
        const textBytes = data.slice(offset, offset + argument);
        const text = new TextDecoder().decode(textBytes);
        return { value: text, offset: offset + argument };
      }

    case 4: // Array
      if (argument < 0) return null;
      {
        const arr: unknown[] = [];
        let currentOffset = offset;
        for (let i = 0; i < argument; i++) {
          const item = decodeCBORValue(data, view, currentOffset);
          if (!item) return null;
          arr.push(item.value);
          currentOffset = item.offset;
        }
        return { value: arr, offset: currentOffset };
      }

    case 5: // Map
      if (argument < 0) return null;
      {
        const map: Record<string, unknown> = {};
        let currentOffset = offset;
        for (let i = 0; i < argument; i++) {
          const key = decodeCBORValue(data, view, currentOffset);
          if (!key) return null;
          const val = decodeCBORValue(data, view, key.offset);
          if (!val) return null;
          map[String(key.value)] = val.value;
          currentOffset = val.offset;
        }
        return { value: map, offset: currentOffset };
      }

    case 7: // Simple values and floats
      if (additionalInfo === 20) return { value: false, offset };
      if (additionalInfo === 21) return { value: true, offset };
      if (additionalInfo === 22) return { value: null, offset };
      return { value: undefined, offset };

    default:
      return null;
  }
}

// ---------------------------------------------------------------------------
// Authenticator Data Parsing
// ---------------------------------------------------------------------------

function parseAuthenticatorData(data: Uint8Array): AuthenticatorData | null {
  // Minimum length: 32 (rpIdHash) + 1 (flags) + 4 (signCount) = 37 bytes
  if (data.length < 37) return null;

  const rpIdHash = data.slice(0, 32);
  const flags = data[32];
  const signCount = new DataView(data.buffer, data.byteOffset + 33, 4).getUint32(0);

  // If attested credential data is present (flags bit 6)
  let aaguid = new Uint8Array(16);
  let credentialId = new Uint8Array(0);

  if (flags & 0x40 && data.length >= 55) {
    aaguid = data.slice(37, 53);
    const credIdLen = new DataView(data.buffer, data.byteOffset + 53, 2).getUint16(0);
    if (data.length >= 55 + credIdLen) {
      credentialId = data.slice(55, 55 + credIdLen);
    }
  }

  return { rpIdHash, flags, signCount, aaguid, credentialId };
}

// ---------------------------------------------------------------------------
// Certificate Chain Verification
// ---------------------------------------------------------------------------

/**
 * Verify that the provided X.509 certificate chain is anchored to the
 * Apple App Attestation Root CA.
 *
 * For each certificate in the chain, verifies:
 *  1. The signature of cert[i] using the public key of cert[i+1].
 *  2. The last certificate's signature using the embedded Apple root CA.
 *  3. Validity period (notBefore / notAfter) for each certificate.
 */
async function verifyCertificateChain(x5c: Uint8Array[]): Promise<boolean> {
  if (x5c.length < 2) return false;

  const rootCaBytes = base64ToUint8Array(APPLE_APP_ATTEST_ROOT_CA_BASE64);
  if (rootCaBytes.length === 0) {
    console.error('Root CA certificate is empty');
    return false;
  }

  if (x5c.length > 5) {
    console.error('Certificate chain unexpectedly long');
    return false;
  }

  // Verify each certificate is non-empty
  for (let i = 0; i < x5c.length; i++) {
    if (x5c[i].length === 0) {
      console.error(`Certificate at index ${i} is empty`);
      return false;
    }
  }

  // Verify chain: each cert[i] should be signed by cert[i+1],
  // and the last cert should be signed by the root CA.
  const allCerts = [...x5c, rootCaBytes];

  for (let i = 0; i < allCerts.length - 1; i++) {
    const certToVerify = allCerts[i];
    const issuerCert = allCerts[i + 1];

    const verified = await verifyCertificateSignature(certToVerify, issuerCert);
    if (!verified) {
      console.error(`Certificate chain verification failed at index ${i}`);
      return false;
    }

    // Verify validity period
    const validity = parseCertificateValidity(certToVerify);
    if (validity) {
      const now = Date.now();
      if (now < validity.notBefore || now > validity.notAfter) {
        console.error(`Certificate at index ${i} is outside validity period`);
        return false;
      }
    }
  }

  return true;
}

/**
 * Convert a DER-encoded ECDSA signature to IEEE P1363 format.
 *
 * DER format:  SEQUENCE { INTEGER r, INTEGER s }
 * P1363 format: r || s  (each zero-padded to `componentLen` bytes)
 *
 * WebCrypto expects P1363; X.509 certificates use DER.
 */
function derSignatureToP1363(derSig: Uint8Array, componentLen: number): Uint8Array | null {
  try {
    let offset = 0;

    if (derSig[offset] !== 0x30) return null;
    offset++;
    if (derSig[offset] & 0x80) {
      offset += (derSig[offset] & 0x7f) + 1;
    } else {
      offset++;
    }

    if (derSig[offset] !== 0x02) return null;
    offset++;
    const rLen = derSig[offset];
    offset++;
    let rBytes = derSig.slice(offset, offset + rLen);
    offset += rLen;

    if (derSig[offset] !== 0x02) return null;
    offset++;
    const sLen = derSig[offset];
    offset++;
    let sBytes = derSig.slice(offset, offset + sLen);

    if (rBytes[0] === 0x00) rBytes = rBytes.slice(1);
    if (sBytes[0] === 0x00) sBytes = sBytes.slice(1);

    const result = new Uint8Array(componentLen * 2);
    result.set(rBytes, componentLen - rBytes.length);
    result.set(sBytes, componentLen * 2 - sBytes.length);

    return result;
  } catch {
    return null;
  }
}

/**
 * Verify that `certDer` was signed by the issuer whose certificate is `issuerDer`.
 */
async function verifyCertificateSignature(
  certDer: Uint8Array,
  issuerDer: Uint8Array,
): Promise<boolean> {
  try {
    // Extract the issuer's public key (SPKI)
    const issuerSPKI = extractSPKIFromCert(issuerDer);
    if (!issuerSPKI) {
      console.error('Failed to extract SPKI from issuer certificate');
      return false;
    }

    // Detect algorithm from SPKI
    const spkiHex = Array.from(issuerSPKI)
      .map(b => b.toString(16).padStart(2, '0'))
      .join('');

    let importAlg: EcKeyImportParams | RsaHashedImportParams;
    let verifyAlg: EcdsaParams | AlgorithmIdentifier;
    let isECDSA = false;
    let ecComponentLen = 32;

    if (spkiHex.includes('2a8648ce3d0201')) {
      // EC key
      isECDSA = true;
      let namedCurve = 'P-256';
      if (spkiHex.includes('2b81040022')) { namedCurve = 'P-384'; ecComponentLen = 48; }
      else if (spkiHex.includes('2b81040023')) { namedCurve = 'P-521'; ecComponentLen = 66; }

      importAlg = { name: 'ECDSA', namedCurve };
      const hashName = namedCurve === 'P-384' ? 'SHA-384' : 'SHA-256';
      verifyAlg = { name: 'ECDSA', hash: { name: hashName } };
    } else {
      importAlg = { name: 'RSASSA-PKCS1-v1_5', hash: { name: 'SHA-256' } };
      verifyAlg = { name: 'RSASSA-PKCS1-v1_5' };
    }

    const issuerKey = await crypto.subtle.importKey(
      'spki',
      issuerSPKI.buffer as ArrayBuffer,
      importAlg,
      true,
      ['verify'],
    );

    // Extract TBSCertificate and signature from certDer
    const certParts = parseCertificateForVerification(certDer);
    if (!certParts) {
      console.error('Failed to parse certificate for signature verification');
      return false;
    }

    // For ECDSA, X.509 signatures are DER-encoded but WebCrypto expects P1363 format
    let signatureBytes = certParts.signature;
    if (isECDSA) {
      const p1363 = derSignatureToP1363(signatureBytes, ecComponentLen);
      if (!p1363) {
        console.error('Failed to convert ECDSA signature from DER to P1363');
        return false;
      }
      signatureBytes = p1363;
    }

    return await crypto.subtle.verify(
      verifyAlg,
      issuerKey,
      signatureBytes,
      certParts.tbsCertificate,
    );
  } catch (error) {
    console.error('Certificate signature verification error:', error);
    return false;
  }
}

interface CertificateParts {
  tbsCertificate: Uint8Array;
  signature: Uint8Array;
}

/**
 * Parse a DER certificate to extract TBSCertificate bytes and signature.
 */
function parseCertificateForVerification(certDer: Uint8Array): CertificateParts | null {
  try {
    // Outer SEQUENCE
    const outerSeq = parseASN1Tag(certDer, 0);
    if (!outerSeq || outerSeq.tag !== 0x30) return null;

    // TBSCertificate (first element)
    const tbsSeq = parseASN1Tag(certDer, outerSeq.contentOffset);
    if (!tbsSeq || tbsSeq.tag !== 0x30) return null;

    const tbsEnd = tbsSeq.contentOffset + tbsSeq.contentLength;
    const tbsCertificate = certDer.slice(outerSeq.contentOffset, tbsEnd);

    // SignatureAlgorithm (second element) — skip
    const sigAlgSeq = parseASN1Tag(certDer, tbsEnd);
    if (!sigAlgSeq) return null;
    const sigAlgEnd = sigAlgSeq.contentOffset + sigAlgSeq.contentLength;

    // Signature BIT STRING (third element)
    const sigBitString = parseASN1Tag(certDer, sigAlgEnd);
    if (!sigBitString || sigBitString.tag !== 0x03) return null;

    // Skip the unused-bits byte (first byte of BIT STRING content)
    const signature = certDer.slice(
      sigBitString.contentOffset + 1,
      sigBitString.contentOffset + sigBitString.contentLength,
    );

    return { tbsCertificate, signature };
  } catch {
    return null;
  }
}

/**
 * Parse certificate validity period (notBefore / notAfter) from DER.
 */
function parseCertificateValidity(
  certDer: Uint8Array,
): { notBefore: number; notAfter: number } | null {
  try {
    const outerSeq = parseASN1Tag(certDer, 0);
    if (!outerSeq || outerSeq.tag !== 0x30) return null;

    const tbsSeq = parseASN1Tag(certDer, outerSeq.contentOffset);
    if (!tbsSeq || tbsSeq.tag !== 0x30) return null;

    let fieldOffset = tbsSeq.contentOffset;

    // Skip version if present
    const firstField = parseASN1Tag(certDer, fieldOffset);
    if (firstField && firstField.tag === 0xa0) {
      fieldOffset = firstField.contentOffset + firstField.contentLength;
    }

    // Skip serialNumber, signatureAlgorithm, issuer (3 fields)
    for (let i = 0; i < 3; i++) {
      const field = parseASN1Tag(certDer, fieldOffset);
      if (!field) return null;
      fieldOffset = field.contentOffset + field.contentLength;
    }

    // Validity SEQUENCE
    const validitySeq = parseASN1Tag(certDer, fieldOffset);
    if (!validitySeq || validitySeq.tag !== 0x30) return null;

    // notBefore
    const notBeforeTag = parseASN1Tag(certDer, validitySeq.contentOffset);
    if (!notBeforeTag) return null;
    const notBeforeStr = new TextDecoder().decode(
      certDer.slice(notBeforeTag.contentOffset, notBeforeTag.contentOffset + notBeforeTag.contentLength),
    );
    const notBefore = parseASN1Time(notBeforeStr, notBeforeTag.tag);

    // notAfter
    const notAfterOffset = notBeforeTag.contentOffset + notBeforeTag.contentLength;
    const notAfterTag = parseASN1Tag(certDer, notAfterOffset);
    if (!notAfterTag) return null;
    const notAfterStr = new TextDecoder().decode(
      certDer.slice(notAfterTag.contentOffset, notAfterTag.contentOffset + notAfterTag.contentLength),
    );
    const notAfter = parseASN1Time(notAfterStr, notAfterTag.tag);

    return { notBefore, notAfter };
  } catch {
    return null;
  }
}

function parseASN1Time(timeStr: string, tag: number): number {
  // UTCTime (0x17): YYMMDDHHMMSSZ
  // GeneralizedTime (0x18): YYYYMMDDHHMMSSZ
  if (tag === 0x17) {
    // UTCTime
    const yy = parseInt(timeStr.slice(0, 2), 10);
    const year = yy >= 50 ? 1900 + yy : 2000 + yy;
    const month = parseInt(timeStr.slice(2, 4), 10) - 1;
    const day = parseInt(timeStr.slice(4, 6), 10);
    const hour = parseInt(timeStr.slice(6, 8), 10);
    const minute = parseInt(timeStr.slice(8, 10), 10);
    const second = parseInt(timeStr.slice(10, 12), 10);
    return Date.UTC(year, month, day, hour, minute, second);
  } else {
    // GeneralizedTime
    const year = parseInt(timeStr.slice(0, 4), 10);
    const month = parseInt(timeStr.slice(4, 6), 10) - 1;
    const day = parseInt(timeStr.slice(6, 8), 10);
    const hour = parseInt(timeStr.slice(8, 10), 10);
    const minute = parseInt(timeStr.slice(10, 12), 10);
    const second = parseInt(timeStr.slice(12, 14), 10);
    return Date.UTC(year, month, day, hour, minute, second);
  }
}

// ---------------------------------------------------------------------------
// ASN.1 Parsing
// ---------------------------------------------------------------------------

interface ASN1Element {
  tag: number;
  contentOffset: number;
  contentLength: number;
}

function parseASN1Tag(data: Uint8Array, offset: number): ASN1Element | null {
  if (offset >= data.length) return null;

  const tag = data[offset];
  offset++;

  let length: number;
  if (data[offset] < 0x80) {
    length = data[offset];
    offset++;
  } else {
    const numLengthBytes = data[offset] & 0x7f;
    offset++;
    length = 0;
    for (let i = 0; i < numLengthBytes; i++) {
      length = (length << 8) | data[offset];
      offset++;
    }
  }

  return { tag, contentOffset: offset, contentLength: length };
}

// ---------------------------------------------------------------------------
// Utility Functions
// ---------------------------------------------------------------------------

function base64ToUint8Array(base64: string): Uint8Array {
  const binaryString = atob(base64);
  const bytes = new Uint8Array(binaryString.length);
  for (let i = 0; i < binaryString.length; i++) {
    bytes[i] = binaryString.charCodeAt(i);
  }
  return bytes;
}

function uint8ArrayToBase64(bytes: Uint8Array): string {
  let binaryString = '';
  for (let i = 0; i < bytes.length; i++) {
    binaryString += String.fromCharCode(bytes[i]);
  }
  return btoa(binaryString);
}

async function sha256(data: Uint8Array): Promise<Uint8Array> {
  const hash = await crypto.subtle.digest('SHA-256', data);
  return new Uint8Array(hash);
}

function uint8ArrayEquals(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}

function concatUint8Arrays(a: Uint8Array, b: Uint8Array): Uint8Array {
  const result = new Uint8Array(a.length + b.length);
  result.set(a, 0);
  result.set(b, a.length);
  return result;
}
