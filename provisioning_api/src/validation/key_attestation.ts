// ---------------------------------------------------------------------------
// Android Key Attestation Validation
//
// Verifies that a certificate chain produced by Android Key Attestation
// is rooted at Google's Hardware Attestation Root CA and that the key
// was generated inside a Trusted Execution Environment (TEE) or StrongBox
// on this specific device, bound to a server-issued challenge.
//
// This closes the gap where Play Integrity proves "real device, real app"
// but NOT "this CSR was generated on this device's hardware." Without Key
// Attestation an attacker could proxy a Play Integrity token while
// submitting a CSR from a different machine.
//
// Reference:
//   https://developer.android.com/privacy-and-security/security-key-attestation
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface KeyAttestationParams {
  /** Base64-encoded DER certificates: [leaf, intermediate, ..., root] */
  certChain: string[];
  /** Expected attestation challenge (the raw challenge string). */
  expectedChallenge: string;
}

export interface KeyAttestationResult {
  valid: boolean;
  /** DER-encoded SubjectPublicKeyInfo from the leaf cert. */
  publicKeyDer?: Uint8Array;
  error?: string;
}

// ---------------------------------------------------------------------------
// Attestation Security Levels (from Android Key Attestation spec)
// ---------------------------------------------------------------------------

/** Software-enforced attestation (least secure). */
const SECURITY_LEVEL_SOFTWARE = 0;
/** TEE-enforced attestation (hardware-backed). */
const SECURITY_LEVEL_TRUSTED_ENVIRONMENT = 1;
/** StrongBox-enforced attestation (most secure). */
const SECURITY_LEVEL_STRONG_BOX = 2;

// ---------------------------------------------------------------------------
// Google Hardware Attestation Root CA Certificates
//
// Source: https://developer.android.com/privacy-and-security/security-key-attestation#root_certificate
// Both certificates must be accepted: the RSA-based root (active since 2022)
// and the new ECDSA P-384 root (effective February 1, 2026).
// ---------------------------------------------------------------------------

/**
 * Google Hardware Attestation Root CA (RSA-4096).
 * Valid: 2022-03-20 to 2042-03-15.
 * Serial: f1c172a699eaf51d
 */
const GOOGLE_ROOT_CA_RSA_PEM = `-----BEGIN CERTIFICATE-----
MIIFHDCCAwSgAwIBAgIJAPHBcqaZ6vUdMA0GCSqGSIb3DQEBCwUAMBsxGTAXBgNV
BAUTEGY5MjAwOWU4NTNiNmIwNDUwHhcNMjIwMzIwMTgwNzQ4WhcNNDIwMzE1MTgw
NzQ4WjAbMRkwFwYDVQQFExBmOTIwMDllODUzYjZiMDQ1MIICIjANBgkqhkiG9w0B
AQEFAAOCAg8AMIICCgKCAgEAr7bHgiuxpwHsK7Qui8xUFmOr75gvMsd/dTEDDJdS
Sxtf6An7xyqpRR90PL2abxM1dEqlXnf2tqw1Ne4Xwl5jlRfdnJLmN0pTy/4lj4/7
tv0Sk3iiKkypnEUtR6WfMgH0QZfKHM1+di+y9TFRtv6y//0rb+T+W8a9nsNL/ggj
nar86461qO0rOs2cXjp3kOG1FEJ5MVmFmBGtnrKpa73XpXyTqRxB/M0n1n/W9nGq
C4FSYa04T6N5RIZGBN2z2MT5IKGbFlbC8UrW0DxW7AYImQQcHtGl/m00QLVWutHQ
oVJYnFPlXTcHYvASLu+RhhsbDmxMgJJ0mcDpvsC4PjvB+TxywElgS70vE0XmLD+O
JtvsBslHZvPBKCOdT0MS+tgSOIfga+z1Z1g7+DVagf7quvmag8jfPioyKvxnK/Eg
sTUVi2ghzq8wm27ud/mIM7AY2qEORR8Go3TVB4HzWQgpZrt3i5MIlCaY504LzSRi
igHCzAPlHws+W0rB5N+er5/2pJKnfBSDiCiFAVtCLOZ7gLiMm0jhO2B6tUXHI/+M
RPjy02i59lINMRRev56GKtcd9qO/0kUJWdZTdA2XoS82ixPvZtXQpUpuL12ab+9E
aDK8Z4RHJYYfCT3Q5vNAXaiWQ+8PTWm2QgBR/bkwSWc+NpUFgNPN9PvQi8WEg5Um
AGMCAwEAAaNjMGEwHQYDVR0OBBYEFDZh4QB8iAUJUYtEbEf/GkzJ6k8SMB8GA1Ud
IwQYMBaAFDZh4QB8iAUJUYtEbEf/GkzJ6k8SMA8GA1UdEwEB/wQFMAMBAf8wDgYD
VR0PAQH/BAQDAgIEMA0GCSqGSIb3DQEBCwUAA4ICAQB8cMqTllHc8U+qCrOlg3H7
174lmaCsbo/bJ0C17JEgMLb4kvrqsXZs01U3mB/qABg/1t5Pd5AORHARs1hhqGIC
W/nKMav574f9rZN4PC2ZlufGXb7sIdJpGiO9ctRhiLuYuly10JccUZGEHpHSYM2G
tkgYbZba6lsCPYAAP83cyDV+1aOkTf1RCp/lM0PKvmxYN10RYsK631jrleGdcdkx
oSK//mSQbgcWnmAEZrzHoF1/0gso1HZgIn0YLzVhLSA/iXCX4QT2h3J5z3znluKG
1nv8NQdxei2DIIhASWfu804CA96cQKTTlaae2fweqXjdN1/v2nqOhngNyz1361mF
mr4XmaKH/ItTwOe72NI9ZcwS1lVaCvsIkTDCEXdm9rCNPAY10iTunIHFXRh+7KPz
lHGewCq/8TOohBRn0/NNfh7uRslOSZ/xKbN9tMBtw37Z8d2vvnXq/YWdsm1+JLVw
n6yYD/yacNJBlwpddla8eaVMjsF6nBnIgQOf9zKSe06nSTqvgwUHosgOECZJZ1Eu
zbH4yswbt02tKtKEFhx+v+OTge/06V+jGsqTWLsfrOCNLuA8H++z+pUENmpqnnHo
vaI47gC+TNpkgYGkkBT6B/m/U01BuOBBTzhIlMEZq9qkDWuM2cA5kW5V3FJUcfHn
w1IdYIg2Wxg7yHcQZemFQg==
-----END CERTIFICATE-----`;

/**
 * Google Key Attestation CA1 (ECDSA P-384, new root).
 * Effective February 1, 2026.
 */
const GOOGLE_ROOT_CA_ECC_PEM = `-----BEGIN CERTIFICATE-----
MIICIjCCAaigAwIBAgIRAISp0Cl7DrWK5/8OgN52BgUwCgYIKoZIzj0EAwMwUjEc
MBoGA1UEAwwTS2V5IEF0dGVzdGF0aW9uIENBMTEQMA4GA1UECwwHQW5kcm9pZDET
MBEGA1UECgwKR29vZ2xlIExMQzELMAkGA1UEBhMCVVMwHhcNMjUwNzE3MjIzMjE4
WhcNMzUwNzE1MjIzMjE4WjBSMRwwGgYDVQQDDBNLZXkgQXR0ZXN0YXRpb24gQ0Ex
MRAwDgYDVQQLDAdBbmRyb2lkMRMwEQYDVQQKDApHb29nbGUgTExDMQswCQYDVQQG
EwJVUzB2MBAGByqGSM49AgEGBSuBBAAiA2IABCPaI3FO3z5bBQo8cuiEas4HjqCt
G/mLFfRT0MsIssPBEEU5Cfbt6sH5yOAxqEi5QagpU1yX4HwnGb7OtBYpDTB57uH5
Eczm34A5FNijV3s0/f0UPl7zbJcTx6xwqMIRq6NCMEAwDwYDVR0TAQH/BAUwAwEB
/zAOBgNVHQ8BAf8EBAMCAQYwHQYDVR0OBBYEFFIyuyz7RkOb3NaBqQ5lZuA0QepA
MAoGCCqGSM49BAMDA2gAMGUCMETfjPO/HwqReR2CS7p0ZWoD/LHs6hDi422opifH
EUaYLxwGlT9SLdjkVpz0UUOR5wIxAIoGyxGKRHVTpqpGRFiJtQEOOTp/+s1GcxeY
uR2zh/80lQyu9vAFCj6E4AXc+osmRg==
-----END CERTIFICATE-----`;

// ---------------------------------------------------------------------------
// Key Attestation Extension OID
// OID 1.3.6.1.4.1.11129.2.1.17 encoded as DER
// ---------------------------------------------------------------------------

const KEY_ATTESTATION_OID_BYTES = new Uint8Array([
  0x06, 0x0a, // OID tag, length 10
  0x2b, 0x06, 0x01, 0x04, 0x01, 0xd6, 0x79, 0x02, 0x01, 0x11,
]);

// Just the OID value bytes (without the tag/length) for searching
const KEY_ATTESTATION_OID_VALUE = new Uint8Array([
  0x2b, 0x06, 0x01, 0x04, 0x01, 0xd6, 0x79, 0x02, 0x01, 0x11,
]);

// ---------------------------------------------------------------------------
// Main Validation Function
// ---------------------------------------------------------------------------

/**
 * Validate an Android Key Attestation certificate chain.
 *
 * Verification steps:
 *  1. Parse cert chain from Base64 DER.
 *  2. Verify signatures: leaf signed by intermediate, ... up to root.
 *  3. Verify the root matches one of Google's Hardware Attestation Root CAs.
 *  4. Parse ASN.1 Key Attestation extension (OID 1.3.6.1.4.1.11129.2.1.17).
 *  5. Verify attestationChallenge matches expectedChallenge.
 *  6. Verify attestationSecurityLevel >= TrustedEnvironment (1).
 *  7. Extract SubjectPublicKeyInfo from leaf cert.
 *  8. Return { valid: true, publicKeyDer }.
 */
export async function validateKeyAttestation(
  params: KeyAttestationParams,
): Promise<KeyAttestationResult> {
  try {
    // ---- 1. Parse cert chain from Base64 DER ----
    if (!params.certChain || params.certChain.length < 2) {
      return { valid: false, error: 'Certificate chain must have at least 2 certificates' };
    }

    const certsDer: Uint8Array[] = [];
    for (let i = 0; i < params.certChain.length; i++) {
      try {
        certsDer.push(base64ToUint8Array(params.certChain[i]));
      } catch {
        return { valid: false, error: `Failed to decode certificate at index ${i}` };
      }
    }

    // ---- 2. Verify the root cert matches a known Google root CA ----
    const chainRoot = certsDer[certsDer.length - 1];
    const googleRSARoot = pemToDer(GOOGLE_ROOT_CA_RSA_PEM);
    const googleECCRoot = pemToDer(GOOGLE_ROOT_CA_ECC_PEM);

    const matchesRSARoot = uint8ArrayEquals(chainRoot, googleRSARoot);
    const matchesECCRoot = uint8ArrayEquals(chainRoot, googleECCRoot);

    if (!matchesRSARoot && !matchesECCRoot) {
      // The chain root may be signed BY a Google root rather than
      // being the root itself. Try verifying the chain root against
      // both known Google root CAs.
      const verifiedByRSA = await verifyCertificateSignature(chainRoot, googleRSARoot);
      const verifiedByECC = await verifyCertificateSignature(chainRoot, googleECCRoot);

      if (!verifiedByRSA && !verifiedByECC) {
        return {
          valid: false,
          error: 'Root certificate does not match any known Google Hardware Attestation Root CA',
        };
      }
    }

    // ---- 3. Check certificate validity periods ----
    for (let i = 0; i < certsDer.length; i++) {
      if (!checkCertValidity(certsDer[i])) {
        return {
          valid: false,
          error: 'Certificate in chain has expired',
        };
      }
    }

    // ---- 3a. Verify chain signatures ----
    // Each cert[i] must be signed by cert[i+1].
    for (let i = 0; i < certsDer.length - 1; i++) {
      const verified = await verifyCertificateSignature(certsDer[i], certsDer[i + 1]);
      if (!verified) {
        return {
          valid: false,
          error: `Certificate chain signature verification failed at index ${i}`,
        };
      }
    }

    // ---- 4. Parse Key Attestation extension from leaf cert ----
    const leafCert = certsDer[0];
    const attestationExt = parseKeyAttestationExtension(leafCert);
    if (!attestationExt) {
      return {
        valid: false,
        error: 'Key Attestation extension (OID 1.3.6.1.4.1.11129.2.1.17) not found in leaf certificate',
      };
    }

    // ---- 5. Verify attestation challenge ----
    const expectedChallengeBytes = new TextEncoder().encode(params.expectedChallenge);
    if (!uint8ArrayEquals(attestationExt.attestationChallenge, expectedChallengeBytes)) {
      return {
        valid: false,
        error: 'Attestation challenge does not match expected value',
      };
    }

    // ---- 6. Verify security level ----
    if (attestationExt.attestationSecurityLevel < SECURITY_LEVEL_TRUSTED_ENVIRONMENT) {
      return {
        valid: false,
        error: `Attestation security level ${attestationExt.attestationSecurityLevel} is below TrustedEnvironment (${SECURITY_LEVEL_TRUSTED_ENVIRONMENT})`,
      };
    }

    // ---- 7. Extract SPKI from leaf cert ----
    const publicKeyDer = extractSPKIFromCert(leafCert);
    if (!publicKeyDer) {
      return {
        valid: false,
        error: 'Failed to extract SubjectPublicKeyInfo from leaf certificate',
      };
    }

    // ---- 8. Success ----
    return { valid: true, publicKeyDer };
  } catch (error) {
    const msg = error instanceof Error ? error.message : String(error);
    return { valid: false, error: `Key attestation validation error: ${msg}` };
  }
}

// ---------------------------------------------------------------------------
// Key Attestation Extension Parsing
//
// The extension has OID 1.3.6.1.4.1.11129.2.1.17 and contains an ASN.1
// SEQUENCE with the following structure (simplified):
//
//   KeyDescription ::= SEQUENCE {
//     attestationVersion    INTEGER,
//     attestationSecurityLevel  SecurityLevel,  -- ENUMERATED
//     keymasterVersion      INTEGER,
//     keymasterSecurityLevel SecurityLevel,
//     attestationChallenge   OCTET STRING,
//     uniqueId              OCTET STRING,
//     softwareEnforced      AuthorizationList,
//     teeEnforced           AuthorizationList,
//   }
// ---------------------------------------------------------------------------

interface KeyAttestationExtension {
  attestationVersion: number;
  attestationSecurityLevel: number;
  attestationChallenge: Uint8Array;
}

/**
 * Find and parse the Key Attestation extension from a DER certificate.
 *
 * Searches the certificate's extensions for the OID, then parses the
 * SEQUENCE to extract the challenge and security level.
 */
function parseKeyAttestationExtension(
  certDer: Uint8Array,
): KeyAttestationExtension | null {
  // Find the Key Attestation OID in the certificate DER
  const oidOffset = findOIDInCert(certDer, KEY_ATTESTATION_OID_VALUE);
  if (oidOffset === -1) return null;

  // The OID is inside an Extension SEQUENCE:
  //   SEQUENCE {
  //     OID,
  //     [BOOLEAN critical OPTIONAL],
  //     OCTET STRING { <extension value> }
  //   }
  // We need to find the OCTET STRING after the OID.
  // findOIDInCert already returns the position right after the OID TLV.
  let offset = oidOffset;

  // Skip optional critical BOOLEAN
  if (offset < certDer.length && certDer[offset] === 0x01) {
    const boolTag = parseASN1Tag(certDer, offset);
    if (boolTag) offset = boolTag.contentOffset + boolTag.contentLength;
  }

  // Read the OCTET STRING wrapper
  const octetTag = parseASN1Tag(certDer, offset);
  if (!octetTag || octetTag.tag !== 0x04) return null;

  // Inside the OCTET STRING is the KeyDescription SEQUENCE
  const extData = certDer.slice(
    octetTag.contentOffset,
    octetTag.contentOffset + octetTag.contentLength,
  );

  return parseKeyDescription(extData);
}

/**
 * Parse the KeyDescription ASN.1 SEQUENCE from the extension value.
 */
function parseKeyDescription(data: Uint8Array): KeyAttestationExtension | null {
  try {
    // Outer SEQUENCE
    const seq = parseASN1Tag(data, 0);
    if (!seq || seq.tag !== 0x30) return null;

    let offset = seq.contentOffset;

    // 1. attestationVersion (INTEGER)
    const versionTag = parseASN1Tag(data, offset);
    if (!versionTag || versionTag.tag !== 0x02) return null;
    const attestationVersion = readASN1Integer(data, versionTag);
    offset = versionTag.contentOffset + versionTag.contentLength;

    // 2. attestationSecurityLevel (ENUMERATED)
    const secLevelTag = parseASN1Tag(data, offset);
    if (!secLevelTag || secLevelTag.tag !== 0x0a) return null;
    const attestationSecurityLevel = readASN1Integer(data, secLevelTag);
    offset = secLevelTag.contentOffset + secLevelTag.contentLength;

    // 3. keymasterVersion (INTEGER)
    const kmVersionTag = parseASN1Tag(data, offset);
    if (!kmVersionTag || kmVersionTag.tag !== 0x02) return null;
    offset = kmVersionTag.contentOffset + kmVersionTag.contentLength;

    // 4. keymasterSecurityLevel (ENUMERATED)
    const kmSecLevelTag = parseASN1Tag(data, offset);
    if (!kmSecLevelTag || kmSecLevelTag.tag !== 0x0a) return null;
    offset = kmSecLevelTag.contentOffset + kmSecLevelTag.contentLength;

    // 5. attestationChallenge (OCTET STRING)
    const challengeTag = parseASN1Tag(data, offset);
    if (!challengeTag || challengeTag.tag !== 0x04) return null;
    const attestationChallenge = data.slice(
      challengeTag.contentOffset,
      challengeTag.contentOffset + challengeTag.contentLength,
    );

    return {
      attestationVersion,
      attestationSecurityLevel,
      attestationChallenge,
    };
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Certificate Parsing & Verification Utilities
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

  if (offset >= data.length) return null;

  let length: number;
  if (data[offset] < 0x80) {
    length = data[offset];
    offset++;
  } else {
    const numLengthBytes = data[offset] & 0x7f;
    offset++;
    length = 0;
    for (let i = 0; i < numLengthBytes; i++) {
      if (offset >= data.length) return null;
      length = (length << 8) | data[offset];
      offset++;
    }
  }

  return { tag, contentOffset: offset, contentLength: length };
}

/**
 * Read an INTEGER or ENUMERATED value as a JavaScript number.
 */
function readASN1Integer(data: Uint8Array, element: ASN1Element): number {
  let value = 0;
  // Handle sign-extended integers (first byte sets sign)
  if (data[element.contentOffset] & 0x80) {
    value = -1; // Start with all 1s for negative
  }
  for (let i = 0; i < element.contentLength; i++) {
    value = (value << 8) | data[element.contentOffset + i];
  }
  return value;
}

/**
 * Extract SubjectPublicKeyInfo (SPKI) DER bytes from a certificate.
 *
 * Walks the TBSCertificate ASN.1 structure:
 *   SEQUENCE {
 *     version [0] EXPLICIT (optional),
 *     serialNumber,
 *     signatureAlgorithm,
 *     issuer,
 *     validity,
 *     subject,
 *     subjectPublicKeyInfo  <-- this is what we extract
 *     ...
 *   }
 */
function extractSPKIFromCert(certDer: Uint8Array): Uint8Array | null {
  try {
    // Outer Certificate SEQUENCE
    const certSeq = parseASN1Tag(certDer, 0);
    if (!certSeq || certSeq.tag !== 0x30) return null;

    // TBSCertificate SEQUENCE
    const tbsSeq = parseASN1Tag(certDer, certSeq.contentOffset);
    if (!tbsSeq || tbsSeq.tag !== 0x30) return null;

    let fieldOffset = tbsSeq.contentOffset;

    // Skip version if present (context-specific tag [0])
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

    // subjectPublicKeyInfo (SEQUENCE)
    const spkiField = parseASN1Tag(certDer, fieldOffset);
    if (!spkiField || spkiField.tag !== 0x30) return null;

    // Return the complete SPKI including tag and length
    return certDer.slice(fieldOffset, spkiField.contentOffset + spkiField.contentLength);
  } catch {
    return null;
  }
}

/**
 * Search for an OID value in certificate DER bytes.
 * Returns the offset right after the OID tag+length+value, or -1.
 */
function findOIDInCert(certDer: Uint8Array, oidValue: Uint8Array): number {
  // Search for the OID tag (0x06) followed by length and matching value
  for (let i = 0; i < certDer.length - oidValue.length - 2; i++) {
    if (certDer[i] === 0x06) {
      // Check if this looks like our OID
      const tag = parseASN1Tag(certDer, i);
      if (!tag || tag.contentLength !== oidValue.length) continue;

      let matches = true;
      for (let j = 0; j < oidValue.length; j++) {
        if (certDer[tag.contentOffset + j] !== oidValue[j]) {
          matches = false;
          break;
        }
      }

      if (matches) {
        return tag.contentOffset + tag.contentLength;
      }
    }
  }
  return -1;
}

interface CertificateParts {
  tbsCertificate: Uint8Array;
  signature: Uint8Array;
}

/**
 * Parse a DER certificate to extract TBSCertificate bytes and signature.
 *
 * Certificate ::= SEQUENCE {
 *   tbsCertificate     TBSCertificate,
 *   signatureAlgorithm AlgorithmIdentifier,
 *   signatureValue     BIT STRING
 * }
 */
function parseCertificateForVerification(certDer: Uint8Array): CertificateParts | null {
  try {
    const outerSeq = parseASN1Tag(certDer, 0);
    if (!outerSeq || outerSeq.tag !== 0x30) return null;

    // TBSCertificate (first element)
    const tbsSeq = parseASN1Tag(certDer, outerSeq.contentOffset);
    if (!tbsSeq || tbsSeq.tag !== 0x30) return null;

    const tbsEnd = tbsSeq.contentOffset + tbsSeq.contentLength;
    const tbsCertificate = certDer.slice(outerSeq.contentOffset, tbsEnd);

    // SignatureAlgorithm (second element) -- skip
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

    // Outer SEQUENCE
    if (derSig[offset] !== 0x30) return null;
    offset++;
    if (derSig[offset] & 0x80) {
      offset += (derSig[offset] & 0x7f) + 1;
    } else {
      offset++;
    }

    // r INTEGER
    if (derSig[offset] !== 0x02) return null;
    offset++;
    const rLen = derSig[offset];
    offset++;
    let rBytes = derSig.slice(offset, offset + rLen);
    offset += rLen;

    // s INTEGER
    if (derSig[offset] !== 0x02) return null;
    offset++;
    const sLen = derSig[offset];
    offset++;
    let sBytes = derSig.slice(offset, offset + sLen);

    // Strip leading zero padding (DER integers are signed)
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
 *
 * Detects the signature algorithm (RSA or ECDSA, with P-256 or P-384 curves)
 * from the issuer's SPKI and verifies accordingly using WebCrypto.
 */
async function verifyCertificateSignature(
  certDer: Uint8Array,
  issuerDer: Uint8Array,
): Promise<boolean> {
  try {
    const issuerSPKI = extractSPKIFromCert(issuerDer);
    if (!issuerSPKI) {
      console.error('[key-attest] Failed to extract SPKI from issuer certificate');
      return false;
    }

    // Detect algorithm from SPKI OID bytes
    const spkiHex = Array.from(issuerSPKI)
      .map((b) => b.toString(16).padStart(2, '0'))
      .join('');

    let importAlg: EcKeyImportParams | RsaHashedImportParams;
    let verifyAlg: EcdsaParams | AlgorithmIdentifier;
    let isECDSA = false;
    let ecComponentLen = 32; // P-256 default

    // Detect the actual hash from the cert's signatureAlgorithm OID
    // (not from the issuer's key curve — a P-384 key can sign with SHA-256)
    const certHex = Array.from(certDer)
      .map((b) => b.toString(16).padStart(2, '0'))
      .join('');

    // ECDSA sig OIDs: ecdsa-with-SHA256=2a8648ce3d040302, SHA384=...03, SHA512=...04
    // RSA sig OIDs: sha256WithRSA=2a864886f70d01010b, sha384=...0c, sha512=...0d, sha1=...05
    let hashName = 'SHA-256'; // safe default
    if (certHex.includes('2a8648ce3d040303') || certHex.includes('2a864886f70d01010c')) {
      hashName = 'SHA-384';
    } else if (certHex.includes('2a8648ce3d040304') || certHex.includes('2a864886f70d01010d')) {
      hashName = 'SHA-512';
    }

    if (spkiHex.includes('2a8648ce3d0201')) {
      // EC key (OID 1.2.840.10045.2.1 = ecPublicKey)
      isECDSA = true;
      let namedCurve = 'P-256';
      if (spkiHex.includes('2b81040022')) { namedCurve = 'P-384'; ecComponentLen = 48; }
      else if (spkiHex.includes('2b81040023')) { namedCurve = 'P-521'; ecComponentLen = 66; }

      importAlg = { name: 'ECDSA', namedCurve };
      verifyAlg = { name: 'ECDSA', hash: { name: hashName } };
    } else {
      // RSA key
      importAlg = { name: 'RSASSA-PKCS1-v1_5', hash: { name: hashName } };
      verifyAlg = { name: 'RSASSA-PKCS1-v1_5' };
    }

    // Copy into a fresh ArrayBuffer to avoid SharedArrayBuffer issues
    const spkiCopy = new Uint8Array(issuerSPKI);
    const issuerKey = await crypto.subtle.importKey(
      'spki',
      spkiCopy.buffer as ArrayBuffer,
      importAlg,
      true,
      ['verify'],
    );

    const certParts = parseCertificateForVerification(certDer);
    if (!certParts) {
      return false;
    }

    // For ECDSA, X.509 signatures are DER-encoded but WebCrypto expects P1363 format
    let signatureBytes = certParts.signature;
    if (isECDSA) {
      const p1363 = derSignatureToP1363(signatureBytes, ecComponentLen);
      if (!p1363) {
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
    console.error('[key-attest] Certificate signature verification error:', error);
    return false;
  }
}

// ---------------------------------------------------------------------------
// Certificate Validity Check
// ---------------------------------------------------------------------------

/**
 * Check that a DER-encoded certificate is within its validity period.
 *
 * Parses the TBSCertificate to find the Validity SEQUENCE (5th element),
 * which contains notBefore and notAfter Time values.
 *
 * @returns true if notBefore <= now <= notAfter, false otherwise.
 */
function checkCertValidity(certDer: Uint8Array): boolean {
  try {
    // Outer Certificate SEQUENCE
    const certSeq = parseASN1Tag(certDer, 0);
    if (!certSeq || certSeq.tag !== 0x30) return false;

    // TBSCertificate SEQUENCE
    const tbsSeq = parseASN1Tag(certDer, certSeq.contentOffset);
    if (!tbsSeq || tbsSeq.tag !== 0x30) return false;

    let fieldOffset = tbsSeq.contentOffset;

    // Skip version if present (context-specific tag [0])
    const firstField = parseASN1Tag(certDer, fieldOffset);
    if (!firstField) return false;
    if (firstField.tag === 0xa0) {
      fieldOffset = firstField.contentOffset + firstField.contentLength;
    }

    // Skip: serialNumber (1), signatureAlgorithm (2), issuer (3) — 3 fields
    for (let i = 0; i < 3; i++) {
      const field = parseASN1Tag(certDer, fieldOffset);
      if (!field) return false;
      fieldOffset = field.contentOffset + field.contentLength;
    }

    // Validity SEQUENCE (4th field after version, index 4 in TBS)
    const validitySeq = parseASN1Tag(certDer, fieldOffset);
    if (!validitySeq || validitySeq.tag !== 0x30) return false;

    // notBefore Time
    const notBeforeTag = parseASN1Tag(certDer, validitySeq.contentOffset);
    if (!notBeforeTag) return false;
    const notBefore = parseASN1Time(
      certDer,
      notBeforeTag.tag,
      notBeforeTag.contentOffset,
      notBeforeTag.contentLength,
    );
    if (!notBefore) return false;

    // notAfter Time
    const notAfterOffset = notBeforeTag.contentOffset + notBeforeTag.contentLength;
    const notAfterTag = parseASN1Tag(certDer, notAfterOffset);
    if (!notAfterTag) return false;
    const notAfter = parseASN1Time(
      certDer,
      notAfterTag.tag,
      notAfterTag.contentOffset,
      notAfterTag.contentLength,
    );
    if (!notAfter) return false;

    const now = Date.now();
    return notBefore.getTime() <= now && now <= notAfter.getTime();
  } catch {
    return false;
  }
}

/**
 * Parse an ASN.1 UTCTime or GeneralizedTime into a Date.
 *
 * UTCTime (tag 0x17): "YYMMDDHHMMSSZ" — 2-digit year (00-49 → 2000s, 50-99 → 1900s)
 * GeneralizedTime (tag 0x18): "YYYYMMDDHHMMSSZ" — 4-digit year
 */
function parseASN1Time(
  data: Uint8Array,
  tag: number,
  offset: number,
  length: number,
): Date | null {
  const timeStr = String.fromCharCode(...data.slice(offset, offset + length));

  let year: number, month: number, day: number;
  let hour: number, minute: number, second: number;

  if (tag === 0x17) {
    // UTCTime: YYMMDDHHMMSSZ
    const yy = parseInt(timeStr.substring(0, 2), 10);
    year = yy < 50 ? 2000 + yy : 1900 + yy;
    month = parseInt(timeStr.substring(2, 4), 10) - 1;
    day = parseInt(timeStr.substring(4, 6), 10);
    hour = parseInt(timeStr.substring(6, 8), 10);
    minute = parseInt(timeStr.substring(8, 10), 10);
    second = parseInt(timeStr.substring(10, 12), 10);
  } else if (tag === 0x18) {
    // GeneralizedTime: YYYYMMDDHHMMSSZ
    year = parseInt(timeStr.substring(0, 4), 10);
    month = parseInt(timeStr.substring(4, 6), 10) - 1;
    day = parseInt(timeStr.substring(6, 8), 10);
    hour = parseInt(timeStr.substring(8, 10), 10);
    minute = parseInt(timeStr.substring(10, 12), 10);
    second = parseInt(timeStr.substring(12, 14), 10);
  } else {
    return null;
  }

  return new Date(Date.UTC(year, month, day, hour, minute, second));
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

function pemToDer(pem: string): Uint8Array {
  const base64 = pem
    .replace(/-----BEGIN [^-]+-----/g, '')
    .replace(/-----END [^-]+-----/g, '')
    .replace(/\s/g, '');
  return base64ToUint8Array(base64);
}

function uint8ArrayEquals(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}
