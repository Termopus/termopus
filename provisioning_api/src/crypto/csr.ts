// ---------------------------------------------------------------------------
// CSR Parsing and Certificate Signing
//
// Handles PKCS#10 Certificate Signing Request parsing and X.509 certificate
// generation using the Web Crypto API available in Cloudflare Workers.
//
// The generated certificates are used by mobile clients for mTLS
// authentication against the Cloudflare Access-protected relay worker.
// ---------------------------------------------------------------------------

import { importPrivateKey, pemToDer, derToPem } from './ca';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface CSRData {
  /** Raw DER-encoded subject from the CSR. */
  subjectDer: Uint8Array;
  /** Raw DER-encoded SubjectPublicKeyInfo from the CSR. */
  publicKeyDer: Uint8Array;
  /** PEM representation of the original CSR. */
  pem: string;
  /** Whether the CSR self-signature was verified (proof-of-possession). */
  signatureVerified: boolean;
}

export interface SignCSRParams {
  /** PEM-encoded PKCS#10 CSR from the client. */
  csr: string;
  /** PEM-encoded CA private key (PKCS#8). */
  caPrivateKey: string;
  /** PEM-encoded CA X.509 certificate. */
  caCertificate: string;
  /** Device identifier to embed in the certificate subject. */
  deviceId: string;
  /** How many days the certificate should be valid. */
  validityDays: number;
}

// ---------------------------------------------------------------------------
// CSR Parsing
// ---------------------------------------------------------------------------

/**
 * Parse a PEM-encoded PKCS#10 CSR and extract the subject and public key.
 *
 * PKCS#10 CertificationRequest structure:
 *   SEQUENCE {
 *     SEQUENCE {                         -- CertificationRequestInfo
 *       INTEGER (version)
 *       SEQUENCE { ... }                 -- subject (Name)
 *       SEQUENCE { ... }                 -- subjectPKInfo
 *       [0] IMPLICIT SET { ... }         -- attributes (optional)
 *     }
 *     SEQUENCE { ... }                   -- signatureAlgorithm
 *     BIT STRING                         -- signature
 *   }
 */
export function parseCSR(pem: string): CSRData | null {
  try {
    // Validate PEM structure
    if (!pem.includes('-----BEGIN CERTIFICATE REQUEST-----') &&
        !pem.includes('-----BEGIN NEW CERTIFICATE REQUEST-----')) {
      console.error('CSR does not have valid PEM headers');
      return null;
    }

    const der = pemToDer(pem);
    if (der.length < 10) {
      console.error('CSR DER data too short');
      return null;
    }

    // Parse outer SEQUENCE (CertificationRequest)
    let offset = 0;
    const outerSeq = parseASN1Tag(der, offset);
    if (!outerSeq || outerSeq.tag !== 0x30) {
      console.error('CSR outer element is not a SEQUENCE');
      return null;
    }

    // Parse CertificationRequestInfo SEQUENCE
    offset = outerSeq.contentOffset;
    const infoSeq = parseASN1Tag(der, offset);
    if (!infoSeq || infoSeq.tag !== 0x30) {
      console.error('CertificationRequestInfo is not a SEQUENCE');
      return null;
    }

    // Walk CertificationRequestInfo fields
    let fieldOffset = infoSeq.contentOffset;

    // Field 0: version (INTEGER)
    const versionField = parseASN1Tag(der, fieldOffset);
    if (!versionField || versionField.tag !== 0x02) {
      console.error('CSR version field is not an INTEGER');
      return null;
    }
    fieldOffset = versionField.contentOffset + versionField.contentLength;

    // Field 1: subject (SEQUENCE — Name)
    const subjectField = parseASN1Tag(der, fieldOffset);
    if (!subjectField || subjectField.tag !== 0x30) {
      console.error('CSR subject is not a SEQUENCE');
      return null;
    }
    const subjectEnd = subjectField.contentOffset + subjectField.contentLength;
    const subjectDer = der.slice(fieldOffset, subjectEnd);
    fieldOffset = subjectEnd;

    // Field 2: subjectPKInfo (SEQUENCE)
    const pkInfoField = parseASN1Tag(der, fieldOffset);
    if (!pkInfoField || pkInfoField.tag !== 0x30) {
      console.error('CSR subjectPKInfo is not a SEQUENCE');
      return null;
    }
    const pkInfoEnd = pkInfoField.contentOffset + pkInfoField.contentLength;
    const publicKeyDer = der.slice(fieldOffset, pkInfoEnd);

    return {
      subjectDer,
      publicKeyDer,
      pem,
      signatureVerified: false, // Set after async verification via verifyCSRSignature()
    };
  } catch (error) {
    console.error('CSR parse error:', error);
    return null;
  }
}

/**
 * Verify the self-signature on a PKCS#10 CSR (proof-of-possession).
 *
 * This proves the requester holds the private key corresponding to the
 * public key in the CSR. The signature covers the CertificationRequestInfo
 * (the first SEQUENCE inside the outer SEQUENCE).
 *
 * Returns the CSRData with `signatureVerified` set to true if valid,
 * or null if verification fails.
 */
export async function verifyCSRSignature(pem: string): Promise<CSRData | null> {
  const csrData = parseCSR(pem);
  if (!csrData) {
    console.error('[csr] parseCSR returned null');
    return null;
  }

  try {
    const der = pemToDer(pem);

    // Parse outer SEQUENCE
    let offset = 0;
    const outerSeq = parseASN1Tag(der, offset);
    if (!outerSeq || outerSeq.tag !== 0x30) {
      console.error('[csr] outer SEQUENCE parse failed');
      return null;
    }

    // Parse CertificationRequestInfo SEQUENCE — this is what's signed
    offset = outerSeq.contentOffset;
    const infoSeq = parseASN1Tag(der, offset);
    if (!infoSeq || infoSeq.tag !== 0x30) {
      console.error('[csr] CertReqInfo SEQUENCE parse failed');
      return null;
    }

    const infoEnd = infoSeq.contentOffset + infoSeq.contentLength;
    const certificationRequestInfo = der.slice(offset, infoEnd);
    offset = infoEnd;

    // Parse signatureAlgorithm SEQUENCE
    const sigAlgSeq = parseASN1Tag(der, offset);
    if (!sigAlgSeq || sigAlgSeq.tag !== 0x30) {
      console.error('[csr] sigAlg SEQUENCE parse failed at offset', offset, 'tag:', der[offset]?.toString(16));
      return null;
    }

    // Detect algorithm from OID
    const sigAlgContent = der.slice(
      sigAlgSeq.contentOffset,
      sigAlgSeq.contentOffset + sigAlgSeq.contentLength,
    );
    const sigAlgHex = Array.from(sigAlgContent)
      .map((b) => b.toString(16).padStart(2, '0'))
      .join('');

    offset = sigAlgSeq.contentOffset + sigAlgSeq.contentLength;

    // Parse signature BIT STRING
    const sigBitString = parseASN1Tag(der, offset);
    if (!sigBitString || sigBitString.tag !== 0x03) {
      console.error('[csr] signature BIT STRING parse failed at offset', offset, 'tag:', der[offset]?.toString(16));
      return null;
    }

    // Skip unused-bits byte (should be 0x00)
    const unusedBits = der[sigBitString.contentOffset];
    if (unusedBits !== 0x00) {
      console.error('[csr] unexpected unused bits:', unusedBits);
      return null;
    }

    const signatureBytes = der.slice(
      sigBitString.contentOffset + 1,
      sigBitString.contentOffset + sigBitString.contentLength,
    );

    // Import the CSR's public key for verification
    let importAlgorithm: RsaHashedImportParams | EcKeyImportParams;
    let verifyAlgorithm: AlgorithmIdentifier | RsaPssParams | EcdsaParams;

    // Check for ECDSA with SHA-256 OID: 2a 86 48 ce 3d 04 03 02
    if (sigAlgHex.includes('2a8648ce3d040302')) {
      // Detect curve from SPKI
      const spkiHex = Array.from(csrData.publicKeyDer)
        .map((b) => b.toString(16).padStart(2, '0'))
        .join('');

      let namedCurve = 'P-256';
      if (spkiHex.includes('2b81040022')) namedCurve = 'P-384';
      else if (spkiHex.includes('2b81040023')) namedCurve = 'P-521';

      importAlgorithm = { name: 'ECDSA', namedCurve };
      verifyAlgorithm = { name: 'ECDSA', hash: { name: 'SHA-256' } };
    } else if (sigAlgHex.includes('2a864886f70d01010b')) {
      importAlgorithm = { name: 'RSASSA-PKCS1-v1_5', hash: { name: 'SHA-256' } };
      verifyAlgorithm = { name: 'RSASSA-PKCS1-v1_5' };
    } else if (sigAlgHex.includes('2a864886f70d010104')) {
      console.error('CSR uses MD5 signature — rejected');
      return null;
    } else {
      console.error('[csr] Unsupported signature algorithm hex:', sigAlgHex);
      return null;
    }

    const publicKey = await crypto.subtle.importKey(
      'spki',
      csrData.publicKeyDer.buffer as ArrayBuffer,
      importAlgorithm,
      false,
      ['verify'],
    );
    // Web Crypto ECDSA verify expects IEEE P1363 format (raw r||s),
    // but Android's SHA256withECDSA produces DER-encoded signatures.
    // Convert DER → P1363 for ECDSA signatures.
    let sigForVerify: Uint8Array = signatureBytes;
    if ((verifyAlgorithm as EcdsaParams).name === 'ECDSA') {
      const p1363 = derSignatureToP1363(signatureBytes);
      if (p1363) {
        sigForVerify = p1363;
      } else {
        console.warn('[csr] P1363 conversion returned null, trying raw bytes');
      }
    }

    const isValid = await crypto.subtle.verify(
      verifyAlgorithm,
      publicKey,
      sigForVerify,
      certificationRequestInfo,
    );

    if (!isValid) {
      console.error('[csr] crypto.subtle.verify returned FALSE');
      // Also try with raw DER bytes as fallback
      if (sigForVerify !== signatureBytes) {
        const isValidRaw = await crypto.subtle.verify(
          verifyAlgorithm,
          publicKey,
          signatureBytes,
          certificationRequestInfo,
        );
        if (isValidRaw) {
          console.warn('[csr] Raw DER signature verified (unexpected format)');
          csrData.signatureVerified = true;
          return csrData;
        }
        console.error('[csr] Raw DER signature also failed');
      }
      return null;
    }

    csrData.signatureVerified = true;
    return csrData;
  } catch (error) {
    console.error('[csr] verifyCSRSignature exception:', error);
    return null;
  }
}

// ---------------------------------------------------------------------------
// Certificate Signing
// ---------------------------------------------------------------------------

/**
 * Sign a CSR with the CA private key and produce a PEM-encoded X.509
 * certificate.
 *
 * The generated certificate:
 *  - Uses the public key from the CSR.
 *  - Has a subject that includes the device ID (CN=device-{deviceId}).
 *  - Is valid from now until now + validityDays.
 *  - Has a random 20-byte serial number.
 *  - Is signed with SHA-256 using the CA key (RSA or ECDSA).
 *
 * Returns the PEM-encoded certificate, or null on failure.
 */
export async function signCSR(params: SignCSRParams): Promise<string | null> {
  try {
    // ---- 1. Parse CSR to get the public key --------------------------------
    const csrData = parseCSR(params.csr);
    if (!csrData) {
      console.error('Cannot sign: CSR parsing failed');
      return null;
    }

    // ---- 2. Import CA private key ------------------------------------------
    const caPrivateKey = await importPrivateKey(params.caPrivateKey);

    // ---- 3. Build TBSCertificate -------------------------------------------
    const now = new Date();
    const notAfter = new Date(now);
    notAfter.setDate(notAfter.getDate() + params.validityDays);

    // Generate random serial number (20 bytes, positive)
    const serialBytes = new Uint8Array(20);
    crypto.getRandomValues(serialBytes);
    serialBytes[0] &= 0x7f; // Ensure positive (clear high bit)

    // Build the subject: CN=device-{deviceId}
    const subjectCN = `device-${params.deviceId}`;
    const subjectDer = buildDistinguishedName(subjectCN);

    // Extract issuer from CA certificate
    const caCertDer = pemToDer(params.caCertificate);
    const issuerDer = extractIssuerFromCert(caCertDer);

    // Detect signature algorithm
    const caKeyAlgorithm = caPrivateKey.algorithm;
    let signatureAlgorithmDer: Uint8Array;
    let signParams: AlgorithmIdentifier | RsaPssParams | EcdsaParams;

    if (caKeyAlgorithm.name === 'RSASSA-PKCS1-v1_5') {
      // sha256WithRSAEncryption: 1.2.840.113549.1.1.11
      signatureAlgorithmDer = buildAlgorithmIdentifier(
        new Uint8Array([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b]),
        true, // RSA includes explicit NULL parameters
      );
      signParams = { name: 'RSASSA-PKCS1-v1_5' };
    } else {
      // ecdsaWithSHA256: 1.2.840.10045.4.3.2
      signatureAlgorithmDer = buildAlgorithmIdentifier(
        new Uint8Array([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02]),
        false,
      );
      signParams = { name: 'ECDSA', hash: { name: 'SHA-256' } };
    }

    // Encode validity
    const validityDer = buildValidity(now, notAfter);

    // Build TBSCertificate
    const tbsCertificate = buildTBSCertificate({
      serialNumber: serialBytes,
      signatureAlgorithm: signatureAlgorithmDer,
      issuer: issuerDer,
      validity: validityDer,
      subject: subjectDer,
      subjectPublicKeyInfo: csrData.publicKeyDer,
    });

    // ---- 4. Sign TBSCertificate --------------------------------------------
    const signatureRaw = await crypto.subtle.sign(
      signParams,
      caPrivateKey,
      tbsCertificate,
    );

    const signatureBytes = new Uint8Array(signatureRaw);

    // Wrap signature in BIT STRING (prepend 0x00 for unused bits)
    const signatureBitString = buildBitString(signatureBytes);

    // ---- 5. Assemble full Certificate --------------------------------------
    const certificateDer = buildSequence(
      concatArrays(tbsCertificate, signatureAlgorithmDer, signatureBitString),
    );

    // ---- 6. Encode to PEM --------------------------------------------------
    return derToPem(certificateDer, 'CERTIFICATE');
  } catch (error) {
    console.error('Certificate signing error:', error);
    return null;
  }
}

// ---------------------------------------------------------------------------
// ASN.1 / DER Construction Helpers
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

/**
 * Build an ASN.1 DER length encoding.
 */
function encodeLength(length: number): Uint8Array {
  if (length < 0x80) {
    return new Uint8Array([length]);
  } else if (length < 0x100) {
    return new Uint8Array([0x81, length]);
  } else if (length < 0x10000) {
    return new Uint8Array([0x82, (length >> 8) & 0xff, length & 0xff]);
  } else if (length < 0x1000000) {
    return new Uint8Array([0x83, (length >> 16) & 0xff, (length >> 8) & 0xff, length & 0xff]);
  } else {
    return new Uint8Array([
      0x84,
      (length >> 24) & 0xff,
      (length >> 16) & 0xff,
      (length >> 8) & 0xff,
      length & 0xff,
    ]);
  }
}

/**
 * Build an ASN.1 SEQUENCE wrapping the given content.
 */
function buildSequence(content: Uint8Array): Uint8Array {
  const lengthBytes = encodeLength(content.length);
  return concatArrays(
    new Uint8Array([0x30]),
    lengthBytes,
    content,
  );
}

/**
 * Build an ASN.1 SET wrapping the given content.
 */
function buildSet(content: Uint8Array): Uint8Array {
  const lengthBytes = encodeLength(content.length);
  return concatArrays(
    new Uint8Array([0x31]),
    lengthBytes,
    content,
  );
}

/**
 * Build an ASN.1 INTEGER from raw bytes.
 */
function buildInteger(bytes: Uint8Array): Uint8Array {
  // If high bit is set, prepend 0x00 to keep it positive
  let data = bytes;
  if (bytes.length > 0 && (bytes[0] & 0x80) !== 0) {
    data = new Uint8Array(bytes.length + 1);
    data[0] = 0x00;
    data.set(bytes, 1);
  }
  const lengthBytes = encodeLength(data.length);
  return concatArrays(new Uint8Array([0x02]), lengthBytes, data);
}

/**
 * Build an ASN.1 BIT STRING from raw signature bytes.
 */
function buildBitString(content: Uint8Array): Uint8Array {
  // BIT STRING: tag 0x03, length, 0x00 (unused bits), content
  const innerLength = content.length + 1;
  const lengthBytes = encodeLength(innerLength);
  return concatArrays(
    new Uint8Array([0x03]),
    lengthBytes,
    new Uint8Array([0x00]),
    content,
  );
}

/**
 * Build an ASN.1 UTF8String.
 */
function buildUTF8String(value: string): Uint8Array {
  const encoded = new TextEncoder().encode(value);
  const lengthBytes = encodeLength(encoded.length);
  return concatArrays(new Uint8Array([0x0c]), lengthBytes, encoded);
}

/**
 * Build an ASN.1 OID from raw OID bytes (already DER-encoded body).
 */
function buildOID(oidBytes: Uint8Array): Uint8Array {
  const lengthBytes = encodeLength(oidBytes.length);
  return concatArrays(new Uint8Array([0x06]), lengthBytes, oidBytes);
}

/**
 * Build an ASN.1 explicitly tagged value: [tagNumber] EXPLICIT content.
 */
function buildExplicitTag(tagNumber: number, content: Uint8Array): Uint8Array {
  const tag = 0xa0 | tagNumber;
  const lengthBytes = encodeLength(content.length);
  return concatArrays(new Uint8Array([tag]), lengthBytes, content);
}

/**
 * Build an ASN.1 GeneralizedTime string.
 */
function buildGeneralizedTime(date: Date): Uint8Array {
  const str = formatGeneralizedTime(date);
  const encoded = new TextEncoder().encode(str);
  const lengthBytes = encodeLength(encoded.length);
  return concatArrays(new Uint8Array([0x18]), lengthBytes, encoded);
}

/**
 * Build an ASN.1 UTCTime string.
 */
function buildUTCTime(date: Date): Uint8Array {
  const str = formatUTCTime(date);
  const encoded = new TextEncoder().encode(str);
  const lengthBytes = encodeLength(encoded.length);
  return concatArrays(new Uint8Array([0x17]), lengthBytes, encoded);
}

/**
 * Format a Date as GeneralizedTime (YYYYMMDDHHMMSSZ).
 */
function formatGeneralizedTime(date: Date): string {
  return (
    date.getUTCFullYear().toString().padStart(4, '0') +
    (date.getUTCMonth() + 1).toString().padStart(2, '0') +
    date.getUTCDate().toString().padStart(2, '0') +
    date.getUTCHours().toString().padStart(2, '0') +
    date.getUTCMinutes().toString().padStart(2, '0') +
    date.getUTCSeconds().toString().padStart(2, '0') +
    'Z'
  );
}

/**
 * Format a Date as UTCTime (YYMMDDHHMMSSZ).
 */
function formatUTCTime(date: Date): string {
  const year = date.getUTCFullYear();
  const yy = (year % 100).toString().padStart(2, '0');
  return (
    yy +
    (date.getUTCMonth() + 1).toString().padStart(2, '0') +
    date.getUTCDate().toString().padStart(2, '0') +
    date.getUTCHours().toString().padStart(2, '0') +
    date.getUTCMinutes().toString().padStart(2, '0') +
    date.getUTCSeconds().toString().padStart(2, '0') +
    'Z'
  );
}

// ---------------------------------------------------------------------------
// X.509 Certificate Construction
// ---------------------------------------------------------------------------

/**
 * Build an AlgorithmIdentifier SEQUENCE.
 *
 *   SEQUENCE {
 *     OID algorithm
 *     [NULL]           -- for RSA algorithms
 *   }
 */
function buildAlgorithmIdentifier(oidBytes: Uint8Array, includeNull: boolean): Uint8Array {
  const oid = buildOID(oidBytes);
  if (includeNull) {
    // NULL: tag 0x05, length 0x00
    const nullValue = new Uint8Array([0x05, 0x00]);
    return buildSequence(concatArrays(oid, nullValue));
  }
  return buildSequence(oid);
}

/**
 * Build a Distinguished Name (DN) with a single CN attribute.
 *
 *   SEQUENCE {
 *     SET {
 *       SEQUENCE {
 *         OID (2.5.4.3 = commonName)
 *         UTF8String value
 *       }
 *     }
 *   }
 */
function buildDistinguishedName(commonName: string): Uint8Array {
  // OID 2.5.4.3 (commonName): 55 04 03
  const cnOid = buildOID(new Uint8Array([0x55, 0x04, 0x03]));
  const cnValue = buildUTF8String(commonName);
  const atv = buildSequence(concatArrays(cnOid, cnValue));
  const rdn = buildSet(atv);
  return buildSequence(rdn);
}

/**
 * Build the Validity SEQUENCE containing notBefore and notAfter.
 *
 * Dates before 2050 use UTCTime; dates from 2050 onwards use
 * GeneralizedTime (per RFC 5280 section 4.1.2.5).
 */
function buildValidity(notBefore: Date, notAfter: Date): Uint8Array {
  const encodeDate = (d: Date) =>
    d.getUTCFullYear() >= 2050 ? buildGeneralizedTime(d) : buildUTCTime(d);

  return buildSequence(concatArrays(encodeDate(notBefore), encodeDate(notAfter)));
}

interface TBSCertificateParams {
  serialNumber: Uint8Array;
  signatureAlgorithm: Uint8Array;
  issuer: Uint8Array;
  validity: Uint8Array;
  subject: Uint8Array;
  subjectPublicKeyInfo: Uint8Array;
}

/**
 * Build the TBSCertificate structure.
 *
 *   SEQUENCE {
 *     [0] EXPLICIT INTEGER (version = v3 = 2)
 *     INTEGER (serialNumber)
 *     SEQUENCE (signatureAlgorithm)
 *     SEQUENCE (issuer)
 *     SEQUENCE (validity)
 *     SEQUENCE (subject)
 *     SEQUENCE (subjectPublicKeyInfo)
 *   }
 */
function buildTBSCertificate(params: TBSCertificateParams): Uint8Array {
  // Version: v3 (integer value 2)
  const version = buildExplicitTag(0, buildInteger(new Uint8Array([0x02])));
  const serial = buildInteger(params.serialNumber);

  return buildSequence(
    concatArrays(
      version,
      serial,
      params.signatureAlgorithm,
      params.issuer,
      params.validity,
      params.subject,
      params.subjectPublicKeyInfo,
    ),
  );
}

/**
 * Extract the issuer Distinguished Name from a DER-encoded X.509
 * certificate.
 *
 * The issuer is the 4th field in TBSCertificate (after version,
 * serialNumber, signatureAlgorithm).
 */
function extractIssuerFromCert(certDer: Uint8Array): Uint8Array {
  try {
    // Parse outer SEQUENCE
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

    let fieldOffset = tbsSeq.contentOffset;

    // Skip version if present (context tag [0])
    const firstField = parseASN1Tag(certDer, fieldOffset);
    if (firstField && firstField.tag === 0xa0) {
      fieldOffset = firstField.contentOffset + firstField.contentLength;
    }

    // Skip serialNumber (INTEGER)
    const serialField = parseASN1Tag(certDer, fieldOffset);
    if (!serialField) throw new Error('Missing serial number');
    fieldOffset = serialField.contentOffset + serialField.contentLength;

    // Skip signatureAlgorithm (SEQUENCE)
    const sigAlgField = parseASN1Tag(certDer, fieldOffset);
    if (!sigAlgField) throw new Error('Missing signature algorithm');
    fieldOffset = sigAlgField.contentOffset + sigAlgField.contentLength;

    // This field is the issuer (SEQUENCE)
    const issuerField = parseASN1Tag(certDer, fieldOffset);
    if (!issuerField || issuerField.tag !== 0x30) {
      throw new Error('Issuer is not a SEQUENCE');
    }

    const issuerEnd = issuerField.contentOffset + issuerField.contentLength;
    return certDer.slice(fieldOffset, issuerEnd);
  } catch (error) {
    console.error('Failed to extract issuer from CA certificate:', error);
    // Fall back to a minimal CN=Unknown issuer
    return buildDistinguishedName('Unknown');
  }
}

// ---------------------------------------------------------------------------
// ECDSA Signature Format Conversion
// ---------------------------------------------------------------------------

/**
 * Convert a DER-encoded ECDSA signature to IEEE P1363 format.
 *
 * DER format: SEQUENCE { INTEGER r, INTEGER s }
 * P1363 format: r || s (each padded to curve byte length, 32 bytes for P-256)
 *
 * Android KeyStore produces DER; Web Crypto expects P1363.
 */
function derSignatureToP1363(derSig: Uint8Array): Uint8Array | null {
  try {
    let offset = 0;

    // Parse outer SEQUENCE
    if (derSig[offset] !== 0x30) return null;
    offset++;
    // Skip length
    if (derSig[offset] & 0x80) {
      offset += (derSig[offset] & 0x7f) + 1;
    } else {
      offset++;
    }

    // Parse r INTEGER
    if (derSig[offset] !== 0x02) return null;
    offset++;
    const rLen = derSig[offset];
    offset++;
    let rBytes = derSig.slice(offset, offset + rLen);
    offset += rLen;

    // Parse s INTEGER
    if (derSig[offset] !== 0x02) return null;
    offset++;
    const sLen = derSig[offset];
    offset++;
    let sBytes = derSig.slice(offset, offset + sLen);

    // Strip leading zero padding (DER integers are signed)
    if (rBytes[0] === 0x00) rBytes = rBytes.slice(1);
    if (sBytes[0] === 0x00) sBytes = sBytes.slice(1);

    // Pad to 32 bytes each (P-256)
    const componentLen = 32;
    const result = new Uint8Array(componentLen * 2);
    result.set(rBytes, componentLen - rBytes.length);
    result.set(sBytes, componentLen * 2 - sBytes.length);

    return result;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Array Utilities
// ---------------------------------------------------------------------------

function concatArrays(...arrays: Uint8Array[]): Uint8Array {
  const totalLength = arrays.reduce((sum, arr) => sum + arr.length, 0);
  const result = new Uint8Array(totalLength);
  let offset = 0;
  for (const arr of arrays) {
    result.set(arr, offset);
    offset += arr.length;
  }
  return result;
}
