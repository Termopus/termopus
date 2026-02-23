// ---------------------------------------------------------------------------
// WebCrypto Algorithm Parameter Types
//
// These types are part of the standard Web Crypto API but are not included
// in @cloudflare/workers-types.  They are used by SubtleCrypto.importKey(),
// SubtleCrypto.sign(), and SubtleCrypto.verify().
//
// Declared globally so they are available without imports, matching browser
// behaviour.
// ---------------------------------------------------------------------------

interface RsaHashedImportParams {
  name: string;
  hash: AlgorithmIdentifier;
}

interface EcKeyImportParams {
  name: string;
  namedCurve: string;
}

interface AlgorithmIdentifier {
  name: string;
  [key: string]: unknown;
}

interface RsaPssParams {
  name: string;
  saltLength: number;
}

interface EcdsaParams {
  name: string;
  hash: AlgorithmIdentifier;
}
