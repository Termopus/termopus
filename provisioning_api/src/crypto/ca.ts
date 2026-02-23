// ---------------------------------------------------------------------------
// CA Key Management
//
// Helpers for importing PEM-encoded keys and certificates into Web Crypto
// CryptoKey objects.  Cloudflare Workers support the Web Crypto API but
// do NOT have access to Node.js crypto — all operations use SubtleCrypto.
//
// The CA private key is used to sign client CSRs.
// The CA certificate is included in provisioning responses so clients can
// build a complete chain.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/** Supported key algorithms for the CA private key. */
export type CAKeyAlgorithm = 'RSA' | 'ECDSA';

export interface CAKeyPair {
  /** The imported private CryptoKey, usable for signing. */
  privateKey: CryptoKey;
  /** Raw DER bytes of the CA certificate. */
  certificateDer: Uint8Array;
  /** The detected algorithm family. */
  algorithm: CAKeyAlgorithm;
}

// ---------------------------------------------------------------------------
// PEM Parsing
// ---------------------------------------------------------------------------

/**
 * Strip PEM headers/footers and decode the base64 body to raw DER bytes.
 *
 * Handles both PKCS#8 private keys and X.509 certificates.
 */
export function pemToDer(pem: string): Uint8Array {
  // Remove all PEM armor lines and whitespace
  const base64 = pem
    .replace(/-----BEGIN [A-Z\s]+-----/g, '')
    .replace(/-----END [A-Z\s]+-----/g, '')
    .replace(/\s+/g, '');

  const binaryString = atob(base64);
  const bytes = new Uint8Array(binaryString.length);
  for (let i = 0; i < binaryString.length; i++) {
    bytes[i] = binaryString.charCodeAt(i);
  }
  return bytes;
}

/**
 * Encode raw DER bytes back to a PEM string with the given label.
 */
export function derToPem(der: Uint8Array, label: string): string {
  const base64 = uint8ArrayToBase64(der);
  const lines: string[] = [];
  lines.push(`-----BEGIN ${label}-----`);
  // Split into 64-character lines per PEM spec
  for (let i = 0; i < base64.length; i += 64) {
    lines.push(base64.slice(i, i + 64));
  }
  lines.push(`-----END ${label}-----`);
  return lines.join('\n');
}

// ---------------------------------------------------------------------------
// Key Import
// ---------------------------------------------------------------------------

/**
 * Detect whether a DER-encoded private key is RSA or ECDSA by inspecting
 * the algorithm OID in the PKCS#8 PrivateKeyInfo structure.
 *
 * PKCS#8 structure:
 *   SEQUENCE {
 *     INTEGER (version)
 *     SEQUENCE {                 <-- AlgorithmIdentifier
 *       OID (algorithm)
 *       [parameters]
 *     }
 *     OCTET STRING (privateKey)
 *   }
 *
 * Known OIDs:
 *   RSA:       1.2.840.113549.1.1.1  (hex: 2a 86 48 86 f7 0d 01 01 01)
 *   ECDSA:     1.2.840.10045.2.1     (hex: 2a 86 48 ce 3d 02 01)
 */
function detectKeyAlgorithm(der: Uint8Array): CAKeyAlgorithm {
  const hex = Array.from(der)
    .map(b => b.toString(16).padStart(2, '0'))
    .join('');

  // RSA OID: 2a 86 48 86 f7 0d 01 01 01
  if (hex.includes('2a864886f70d010101')) {
    return 'RSA';
  }

  // EC OID: 2a 86 48 ce 3d 02 01
  if (hex.includes('2a8648ce3d0201')) {
    return 'ECDSA';
  }

  // Default to RSA — most CAs use RSA
  console.warn('Could not detect key algorithm from OID, defaulting to RSA');
  return 'RSA';
}

/**
 * Detect the ECDSA curve from a PKCS#8 DER-encoded key.
 *
 * Known curve OIDs:
 *   P-256: 1.2.840.10045.3.1.7  (hex: 2a 86 48 ce 3d 03 01 07)
 *   P-384: 1.3.132.0.34         (hex: 2b 81 04 00 22)
 *   P-521: 1.3.132.0.35         (hex: 2b 81 04 00 23)
 */
function detectECCurve(der: Uint8Array): string {
  const hex = Array.from(der)
    .map(b => b.toString(16).padStart(2, '0'))
    .join('');

  if (hex.includes('2a8648ce3d030107')) return 'P-256';
  if (hex.includes('2b81040022')) return 'P-384';
  if (hex.includes('2b81040023')) return 'P-521';

  // Default to P-256
  return 'P-256';
}

/**
 * Import a PEM-encoded PKCS#8 private key into a Web Crypto CryptoKey.
 *
 * The key is imported with the "sign" usage so it can be used to sign
 * client certificates.
 */
export async function importPrivateKey(pem: string): Promise<CryptoKey> {
  const der = pemToDer(pem);
  const algorithm = detectKeyAlgorithm(der);

  let importAlgorithm: RsaHashedImportParams | EcKeyImportParams;

  if (algorithm === 'RSA') {
    importAlgorithm = {
      name: 'RSASSA-PKCS1-v1_5',
      hash: { name: 'SHA-256' },
    };
  } else {
    const namedCurve = detectECCurve(der);
    importAlgorithm = {
      name: 'ECDSA',
      namedCurve,
    };
  }

  return crypto.subtle.importKey(
    'pkcs8',
    der.buffer as ArrayBuffer,
    importAlgorithm,
    false,       // Not extractable — the key stays in the crypto subsystem
    ['sign'],
  );
}

/**
 * Import a PEM-encoded X.509 certificate's public key into a Web Crypto
 * CryptoKey.  This is used to verify signatures, not to sign.
 *
 * Note: Web Crypto cannot import X.509 certificates directly.  We extract
 * the SubjectPublicKeyInfo (SPKI) from the certificate DER and import that.
 *
 * For a full implementation, parse the ASN.1 TBSCertificate to locate the
 * subjectPublicKeyInfo field.  As a pragmatic shortcut, we search for the
 * SPKI structure by OID.
 */
export async function importCertificatePublicKey(pem: string): Promise<CryptoKey> {
  const der = pemToDer(pem);
  const algorithm = detectKeyAlgorithm(der);

  // Extract SPKI from certificate DER.
  // The SPKI is embedded in the TBSCertificate at a known offset.
  const spki = extractSPKIFromCertificate(der);

  let importAlgorithm: RsaHashedImportParams | EcKeyImportParams;

  if (algorithm === 'RSA') {
    importAlgorithm = {
      name: 'RSASSA-PKCS1-v1_5',
      hash: { name: 'SHA-256' },
    };
  } else {
    const namedCurve = detectECCurve(der);
    importAlgorithm = {
      name: 'ECDSA',
      namedCurve,
    };
  }

  return crypto.subtle.importKey(
    'spki',
    spki.buffer as ArrayBuffer,
    importAlgorithm,
    true,
    ['verify'],
  );
}

/**
 * Load both the CA private key and certificate, returning a ready-to-use
 * CAKeyPair.
 */
export async function loadCAKeyPair(
  privateKeyPem: string,
  certificatePem: string,
): Promise<CAKeyPair> {
  const privateKey = await importPrivateKey(privateKeyPem);
  const certificateDer = pemToDer(certificatePem);
  const algorithm = detectKeyAlgorithm(pemToDer(privateKeyPem));

  return { privateKey, certificateDer, algorithm };
}

// ---------------------------------------------------------------------------
// ASN.1 / DER Helpers
// ---------------------------------------------------------------------------

/**
 * Extract the SubjectPublicKeyInfo (SPKI) from a DER-encoded X.509
 * certificate.
 *
 * X.509 certificate structure (simplified):
 *   SEQUENCE {                       -- Certificate
 *     SEQUENCE {                     -- TBSCertificate
 *       [0] EXPLICIT INTEGER         -- version
 *       INTEGER                      -- serialNumber
 *       SEQUENCE { ... }             -- signature algorithm
 *       SEQUENCE { ... }             -- issuer
 *       SEQUENCE { ... }             -- validity
 *       SEQUENCE { ... }             -- subject
 *       SEQUENCE { ... }             -- subjectPublicKeyInfo  <-- we want this
 *       ...
 *     }
 *     SEQUENCE { ... }               -- signatureAlgorithm
 *     BIT STRING                     -- signature
 *   }
 *
 * We walk the ASN.1 structure to find the 7th element of TBSCertificate
 * (0-indexed field 6), which is the subjectPublicKeyInfo.
 */
function extractSPKIFromCertificate(certDer: Uint8Array): Uint8Array {
  try {
    // Parse outer SEQUENCE (Certificate)
    let offset = 0;
    const certSeq = parseASN1Tag(certDer, offset);
    if (!certSeq || certSeq.tag !== 0x30) {
      throw new Error('Certificate is not a SEQUENCE');
    }

    // Parse TBSCertificate SEQUENCE
    offset = certSeq.contentOffset;
    const tbsSeq = parseASN1Tag(certDer, offset);
    if (!tbsSeq || tbsSeq.tag !== 0x30) {
      throw new Error('TBSCertificate is not a SEQUENCE');
    }

    // Walk through TBSCertificate fields
    let fieldOffset = tbsSeq.contentOffset;
    let fieldIndex = 0;

    // If version is present (context tag [0]), it's the first field
    const firstField = parseASN1Tag(certDer, fieldOffset);
    if (firstField && firstField.tag === 0xa0) {
      // Version is present — skip it
      fieldOffset = firstField.contentOffset + firstField.contentLength;
      fieldIndex = 0;
    }

    // Skip: serialNumber, signatureAlgorithm, issuer, validity, subject
    // We need to skip 5 more fields to reach subjectPublicKeyInfo
    const fieldsToSkip = 5;
    for (let i = 0; i < fieldsToSkip; i++) {
      const field = parseASN1Tag(certDer, fieldOffset);
      if (!field) throw new Error(`Failed to parse TBS field at index ${fieldIndex + i}`);
      fieldOffset = field.contentOffset + field.contentLength;
    }

    // The next field is subjectPublicKeyInfo
    const spkiField = parseASN1Tag(certDer, fieldOffset);
    if (!spkiField || spkiField.tag !== 0x30) {
      throw new Error('SubjectPublicKeyInfo is not a SEQUENCE');
    }

    // Return the complete SPKI (tag + length + content)
    const spkiEnd = spkiField.contentOffset + spkiField.contentLength;
    return certDer.slice(fieldOffset, spkiEnd);
  } catch (error) {
    console.error('Failed to extract SPKI from certificate:', error);
    // Fallback: return the entire certificate DER (will likely fail import,
    // but gives a clear error message)
    return certDer;
  }
}

interface ASN1Element {
  /** The raw tag byte. */
  tag: number;
  /** Offset where the content begins (after tag + length bytes). */
  contentOffset: number;
  /** Length of the content in bytes. */
  contentLength: number;
}

/**
 * Parse a single ASN.1 TLV (Tag-Length-Value) element.
 */
function parseASN1Tag(data: Uint8Array, offset: number): ASN1Element | null {
  if (offset >= data.length) return null;

  const tag = data[offset];
  offset++;

  // Parse length
  let length: number;
  if (data[offset] < 0x80) {
    // Short form
    length = data[offset];
    offset++;
  } else {
    // Long form
    const numLengthBytes = data[offset] & 0x7f;
    offset++;
    length = 0;
    for (let i = 0; i < numLengthBytes; i++) {
      length = (length << 8) | data[offset];
      offset++;
    }
  }

  return {
    tag,
    contentOffset: offset,
    contentLength: length,
  };
}

// ---------------------------------------------------------------------------
// Utility
// ---------------------------------------------------------------------------

function uint8ArrayToBase64(bytes: Uint8Array): string {
  let binaryString = '';
  for (let i = 0; i < bytes.length; i++) {
    binaryString += String.fromCharCode(bytes[i]);
  }
  return btoa(binaryString);
}
