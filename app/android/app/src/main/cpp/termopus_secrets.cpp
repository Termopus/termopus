#include <jni.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>
#include <stdio.h>

// ---------------------------------------------------------------------------
// Volatile integrity token — checked before every sensitive operation
// ---------------------------------------------------------------------------
static volatile int g_integrity_token = 0x000000;

// ---------------------------------------------------------------------------
// Secure zero — compiler cannot optimize away
// ---------------------------------------------------------------------------
__attribute__((noinline))
static void secureZero(void* ptr, size_t len) {
    volatile unsigned char* p = (volatile unsigned char*)ptr;
    for (size_t i = 0; i < len; i++) {
        p[i] = 0;
    }
}

// ---------------------------------------------------------------------------
// Secure exit — unhookable crash via hardware trap instruction
// ---------------------------------------------------------------------------
__attribute__((noinline, optnone, noreturn))
static void secureExit() {
    __builtin_trap();
}

// ---------------------------------------------------------------------------
// Self-contained SHA-256 implementation (no external deps on Android)
// ---------------------------------------------------------------------------
static const uint32_t SHA256_K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};

#define ROTR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
#define CH(x, y, z) (((x) & (y)) ^ (~(x) & (z)))
#define MAJ(x, y, z) (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))
#define EP0(x) (ROTR(x, 2) ^ ROTR(x, 13) ^ ROTR(x, 22))
#define EP1(x) (ROTR(x, 6) ^ ROTR(x, 11) ^ ROTR(x, 25))
#define SIG0(x) (ROTR(x, 7) ^ ROTR(x, 18) ^ ((x) >> 3))
#define SIG1(x) (ROTR(x, 17) ^ ROTR(x, 19) ^ ((x) >> 10))

struct SHA256_CTX {
    unsigned char data[64];
    uint32_t datalen;
    uint64_t bitlen;
    uint32_t state[8];
};

static void sha256_transform(SHA256_CTX* ctx, const unsigned char data[]) {
    uint32_t a, b, c, d, e, f, g, h, t1, t2, m[64];

    for (int i = 0, j = 0; i < 16; i++, j += 4)
        m[i] = ((uint32_t)data[j] << 24) | ((uint32_t)data[j+1] << 16)
              | ((uint32_t)data[j+2] << 8) | ((uint32_t)data[j+3]);
    for (int i = 16; i < 64; i++)
        m[i] = SIG1(m[i-2]) + m[i-7] + SIG0(m[i-15]) + m[i-16];

    a = ctx->state[0]; b = ctx->state[1]; c = ctx->state[2]; d = ctx->state[3];
    e = ctx->state[4]; f = ctx->state[5]; g = ctx->state[6]; h = ctx->state[7];

    for (int i = 0; i < 64; i++) {
        t1 = h + EP1(e) + CH(e, f, g) + SHA256_K[i] + m[i];
        t2 = EP0(a) + MAJ(a, b, c);
        h = g; g = f; f = e; e = d + t1;
        d = c; c = b; b = a; a = t1 + t2;
    }

    ctx->state[0] += a; ctx->state[1] += b; ctx->state[2] += c; ctx->state[3] += d;
    ctx->state[4] += e; ctx->state[5] += f; ctx->state[6] += g; ctx->state[7] += h;
}

static void sha256_init(SHA256_CTX* ctx) {
    ctx->datalen = 0;
    ctx->bitlen = 0;
    ctx->state[0] = 0x6a09e667; ctx->state[1] = 0xbb67ae85;
    ctx->state[2] = 0x3c6ef372; ctx->state[3] = 0xa54ff53a;
    ctx->state[4] = 0x510e527f; ctx->state[5] = 0x9b05688c;
    ctx->state[6] = 0x1f83d9ab; ctx->state[7] = 0x5be0cd19;
}

static void sha256_update(SHA256_CTX* ctx, const unsigned char data[], size_t len) {
    for (size_t i = 0; i < len; i++) {
        ctx->data[ctx->datalen] = data[i];
        ctx->datalen++;
        if (ctx->datalen == 64) {
            sha256_transform(ctx, ctx->data);
            ctx->bitlen += 512;
            ctx->datalen = 0;
        }
    }
}

static void sha256_final(SHA256_CTX* ctx, unsigned char hash[32]) {
    uint32_t i = ctx->datalen;
    if (ctx->datalen < 56) {
        ctx->data[i++] = 0x80;
        while (i < 56) ctx->data[i++] = 0x00;
    } else {
        ctx->data[i++] = 0x80;
        while (i < 64) ctx->data[i++] = 0x00;
        sha256_transform(ctx, ctx->data);
        memset(ctx->data, 0, 56);
    }
    ctx->bitlen += ctx->datalen * 8;
    ctx->data[63] = (unsigned char)(ctx->bitlen);
    ctx->data[62] = (unsigned char)(ctx->bitlen >> 8);
    ctx->data[61] = (unsigned char)(ctx->bitlen >> 16);
    ctx->data[60] = (unsigned char)(ctx->bitlen >> 24);
    ctx->data[59] = (unsigned char)(ctx->bitlen >> 32);
    ctx->data[58] = (unsigned char)(ctx->bitlen >> 40);
    ctx->data[57] = (unsigned char)(ctx->bitlen >> 48);
    ctx->data[56] = (unsigned char)(ctx->bitlen >> 56);
    sha256_transform(ctx, ctx->data);
    for (i = 0; i < 4; i++) {
        hash[i]    = (ctx->state[0] >> (24 - i * 8)) & 0xff;
        hash[i+4]  = (ctx->state[1] >> (24 - i * 8)) & 0xff;
        hash[i+8]  = (ctx->state[2] >> (24 - i * 8)) & 0xff;
        hash[i+12] = (ctx->state[3] >> (24 - i * 8)) & 0xff;
        hash[i+16] = (ctx->state[4] >> (24 - i * 8)) & 0xff;
        hash[i+20] = (ctx->state[5] >> (24 - i * 8)) & 0xff;
        hash[i+24] = (ctx->state[6] >> (24 - i * 8)) & 0xff;
        hash[i+28] = (ctx->state[7] >> (24 - i * 8)) & 0xff;
    }
}

static void sha256(const unsigned char* data, size_t len, unsigned char hash[32]) {
    SHA256_CTX ctx;
    sha256_init(&ctx);
    sha256_update(&ctx, data, len);
    sha256_final(&ctx, hash);
}

// ---------------------------------------------------------------------------
// HMAC-SHA256 per RFC 2104
// ---------------------------------------------------------------------------
static void hmac_sha256(const unsigned char* key, size_t keylen,
                        const unsigned char* data, size_t datalen,
                        unsigned char out[32]) {
    unsigned char k_ipad[64];
    unsigned char k_opad[64];
    unsigned char tk[32];

    if (keylen > 64) {
        sha256(key, keylen, tk);
        key = tk;
        keylen = 32;
    }

    memset(k_ipad, 0x36, 64);
    memset(k_opad, 0x5c, 64);
    for (size_t i = 0; i < keylen; i++) {
        k_ipad[i] ^= key[i];
        k_opad[i] ^= key[i];
    }

    // inner hash: H(K XOR ipad || data)
    SHA256_CTX ctx;
    sha256_init(&ctx);
    sha256_update(&ctx, k_ipad, 64);
    sha256_update(&ctx, data, datalen);
    unsigned char inner[32];
    sha256_final(&ctx, inner);

    // outer hash: H(K XOR opad || inner)
    sha256_init(&ctx);
    sha256_update(&ctx, k_opad, 64);
    sha256_update(&ctx, inner, 32);
    sha256_final(&ctx, out);

    secureZero(k_ipad, 64);
    secureZero(k_opad, 64);
    secureZero(inner, 32);
    secureZero(tk, 32);
}

// ---------------------------------------------------------------------------
// 3-layer XOR deobfuscation
// ---------------------------------------------------------------------------
static void deobfuscate(const unsigned char* obfuscated,
                        const unsigned char* maskA,
                        const unsigned char* maskB,
                        size_t len,
                        unsigned char* out,
                        unsigned char coef1,
                        unsigned char coef2) {
    for (size_t i = 0; i < len; i++) {
        out[i] = obfuscated[i] ^ maskA[i] ^ maskB[i] ^ ((unsigned char)((i * coef1 + coef2) & 0xFF));
    }
}

// ---------------------------------------------------------------------------
// Obfuscated HMAC key (Android-specific, independent from iOS)
// Generated by scripts/generate-obfuscated-secret.py
// ---------------------------------------------------------------------------
// PLACEHOLDER — will be replaced by generate-obfuscated-secret.py output
static const unsigned char HMAC_KEY_OBFUSCATED[32] = {
    0xA3, 0x7B, 0x12, 0xF4, 0x8E, 0x56, 0xC9, 0x01,
    0xD7, 0x3A, 0x65, 0xB8, 0x4F, 0x92, 0xE1, 0x2D,
    0x78, 0xAB, 0x34, 0xF6, 0x19, 0xCD, 0x80, 0x5E,
    0xB2, 0x47, 0x93, 0xDA, 0x0C, 0x61, 0xA5, 0xF8
};
static const unsigned char HMAC_KEY_MASK_A[32] = {
    0x51, 0x2E, 0x8D, 0x43, 0xB6, 0xF0, 0x17, 0x9A,
    0xC3, 0x68, 0xD5, 0x0F, 0x72, 0xE4, 0xA9, 0x3B,
    0x86, 0x5C, 0x11, 0xC7, 0x4A, 0xBE, 0x63, 0xD8,
    0x05, 0x97, 0xFA, 0x2C, 0x81, 0x49, 0xB3, 0x6E
};
static const unsigned char HMAC_KEY_MASK_B[32] = {
    0xC7, 0x14, 0xA8, 0x5B, 0x39, 0xE2, 0x76, 0xDD,
    0x0A, 0x93, 0x4F, 0x61, 0x88, 0x2F, 0xB5, 0xCA,
    0x53, 0x07, 0xEC, 0x3E, 0xD1, 0x75, 0xA4, 0x16,
    0x69, 0xBB, 0x28, 0xF3, 0x4C, 0x8A, 0xDE, 0x52
};
static const unsigned char HMAC_KEY_COEF1 = 0x00;
static const unsigned char HMAC_KEY_COEF2 = 0x00;

// ---------------------------------------------------------------------------
// Obfuscated relay endpoint
// Generated by scripts/generate-obfuscated-secret.py
// ---------------------------------------------------------------------------
// "wss://YOUR_RELAY_URL"
static const unsigned char ENDPOINT_RELAY_OBFUSCATED[] = {
    0xD4, 0x30, 0x30, 0x7B, 0x72, 0x72, 0x9F, 0xA8,
    0xB6, 0xA2, 0xD0, 0x61, 0x8A, 0xA5, 0xD3, 0x6E,
    0xB7, 0xA1, 0xC8, 0xBF, 0x9E, 0xB8, 0xCA, 0x6E,
    0x8C, 0xB1, 0xA9, 0x00
};
static const unsigned char ENDPOINT_RELAY_MASK_A[] = {
    0xA3, 0x53, 0x53, 0x1A, 0x11, 0x15, 0xFE, 0xCB,
    0xD5, 0xC1, 0xBF, 0x00, 0xEB, 0xC4, 0xBE, 0x0F,
    0xD6, 0xC0, 0xAD, 0xDE, 0xFD, 0xDB, 0xAD, 0x0F,
    0xEB, 0xD0, 0xCA, 0x63
};
static const unsigned char ENDPOINT_RELAY_MASK_B[] = {
    0x66, 0x96, 0x96, 0xDF, 0xD4, 0xD4, 0x3B, 0x0E,
    0x10, 0x04, 0x7C, 0xC5, 0x2E, 0x01, 0x73, 0xCA,
    0x13, 0x05, 0x6C, 0x1B, 0x3A, 0x1C, 0x6E, 0xCA,
    0x2C, 0x15, 0x0D, 0xA6
};
static const unsigned char ENDPOINT_RELAY_COEF1 = 0x00;
static const unsigned char ENDPOINT_RELAY_COEF2 = 0x00;

// ---------------------------------------------------------------------------
// Obfuscated SPKI certificate pin hashes
// ---------------------------------------------------------------------------
// Leaf cert pin (placeholder — will be replaced by generate script)
static const char CERT_PIN_LEAF[] = "sha256/PLACEHOLDER_LEAF_PIN_HASH";
// Intermediate cert pin
static const char CERT_PIN_INTERMEDIATE[] = "sha256/PLACEHOLDER_INTERMEDIATE_PIN_HASH";
// Root cert pin
static const char CERT_PIN_ROOT[] = "sha256/PLACEHOLDER_ROOT_PIN_HASH";

// ---------------------------------------------------------------------------
// Hex encoding helper
// ---------------------------------------------------------------------------
static void hex_encode(const unsigned char* data, size_t len, char* out) {
    static const char hex[] = "0123456789abcdef";
    for (size_t i = 0; i < len; i++) {
        out[i*2]   = hex[(data[i] >> 4) & 0x0F];
        out[i*2+1] = hex[data[i] & 0x0F];
    }
    out[len*2] = '\0';
}

// ---------------------------------------------------------------------------
// Generate MAC for a data string
// ---------------------------------------------------------------------------
static void generateMAC(const char* data, char macOutput[65]) {
    if (g_integrity_token != 0x000000) {
        secureExit();
    }

    unsigned char key[32];
    deobfuscate(HMAC_KEY_OBFUSCATED, HMAC_KEY_MASK_A, HMAC_KEY_MASK_B,
                32, key, HMAC_KEY_COEF1, HMAC_KEY_COEF2);

    unsigned char mac[32];
    hmac_sha256(key, 32, (const unsigned char*)data, strlen(data), mac);
    hex_encode(mac, 32, macOutput);

    secureZero(key, 32);
    secureZero(mac, 32);
}

// ---------------------------------------------------------------------------
// Inline hook detection (architecture-guarded)
// ---------------------------------------------------------------------------
static int checkInlineHooks(void) {
#if defined(__aarch64__)
    void* funcAddr = (void*)checkInlineHooks;
    unsigned char* bytes = (unsigned char*)funcAddr;

    // ARM64: LDR X16, #8; BR X16 = Frida/Substrate trampoline pattern
    if (bytes[0] == 0x50 && bytes[1] == 0x00 &&
        bytes[2] == 0x00 && bytes[3] == 0x58) {
        return 1;
    }

    // ARM64: ADRP + BR X16/X17 — another common trampoline
    // Check for BR X16 (0xD61F0200) or BR X17 (0xD61F0220)
    uint32_t insn;
    memcpy(&insn, bytes + 4, 4);
    if (insn == 0xD61F0200 || insn == 0xD61F0220) {
        return 1;
    }

    return 0;
#elif defined(__arm__)
    // ARM32: Check for LDR PC patterns
    void* funcAddr = (void*)checkInlineHooks;
    unsigned char* bytes = (unsigned char*)funcAddr;
    // BX PC or LDR PC, [PC, #offset]
    if (bytes[3] == 0xE5 && bytes[2] == 0x9F && bytes[1] == 0xF0) {
        return 1;
    }
    return 0;
#else
    // x86/x86_64 (simulators/emulators) — skip hook detection
    return 0;
#endif
}

// ---------------------------------------------------------------------------
// JNI: Sign a security result
// Returns: "STATUS:details:timestamp:hmac_hex"
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_termopus_app_security_NativeSecrets_signSecurityResult(
        JNIEnv* env, jclass, jstring status) {
    if (g_integrity_token != 0x000000) {
        secureExit();
    }

    const char* statusStr = env->GetStringUTFChars(status, nullptr);

    // Format: "STATUS:timestamp"
    char payload[512];
    long timestamp = (long)time(nullptr);
    snprintf(payload, sizeof(payload), "%s:%ld", statusStr, timestamp);

    env->ReleaseStringUTFChars(status, statusStr);

    // Generate HMAC
    char mac[65];
    generateMAC(payload, mac);

    // Result: "STATUS:timestamp:hmac"
    char result[640];
    snprintf(result, sizeof(result), "%s:%s", payload, mac);

    return env->NewStringUTF(result);
}

// ---------------------------------------------------------------------------
// JNI: Enforce a signed security result (void return — crashes on failure)
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT void JNICALL
Java_com_termopus_app_security_NativeSecrets_enforceSecurityResult(
        JNIEnv* env, jclass, jstring signedResult) {
    if (g_integrity_token != 0x000000) {
        secureExit();
    }

    const char* resultStr = env->GetStringUTFChars(signedResult, nullptr);

    // Parse: find last ':' which separates the HMAC from the payload
    const char* lastColon = strrchr(resultStr, ':');
    if (!lastColon || lastColon == resultStr) {
        env->ReleaseStringUTFChars(signedResult, resultStr);
        secureExit();
        return; // unreachable
    }

    // Extract payload and provided HMAC
    size_t payloadLen = (size_t)(lastColon - resultStr);
    char payload[512];
    if (payloadLen >= sizeof(payload)) {
        env->ReleaseStringUTFChars(signedResult, resultStr);
        secureExit();
        return;
    }
    memcpy(payload, resultStr, payloadLen);
    payload[payloadLen] = '\0';

    const char* providedMAC = lastColon + 1;

    // Recompute HMAC
    char expectedMAC[65];
    generateMAC(payload, expectedMAC);

    // Constant-time comparison
    int diff = 0;
    if (strlen(providedMAC) != 64) {
        diff = 1;
    } else {
        for (int i = 0; i < 64; i++) {
            diff |= providedMAC[i] ^ expectedMAC[i];
        }
    }

    // Check timestamp freshness (< 30 seconds)
    if (diff == 0) {
        // Find timestamp in payload — it's after the last ':' before the MAC
        // Payload format: "STATUS:details:timestamp" or "STATUS:timestamp"
        const char* tsColon = strrchr(payload, ':');
        if (tsColon) {
            long ts = atol(tsColon + 1);
            long now = (long)time(nullptr);
            if (now - ts > 30 || ts - now > 5) { // 30s past, 5s future tolerance
                diff = 1;
            }
        } else {
            diff = 1;
        }
    }

    env->ReleaseStringUTFChars(signedResult, resultStr);
    secureZero(payload, sizeof(payload));
    secureZero(expectedMAC, 65);

    if (diff != 0) {
        secureExit(); // Unhookable crash
    }

    // Also check inline hooks while we're here
    if (checkInlineHooks()) {
        secureExit();
    }
}

// ---------------------------------------------------------------------------
// JNI: Verify certificate pin — returns signed result
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_termopus_app_security_NativeSecrets_verifyCertificatePin(
        JNIEnv* env, jclass, jstring spkiHash) {
    if (g_integrity_token != 0x000000) {
        secureExit();
    }

    const char* hashStr = env->GetStringUTFChars(spkiHash, nullptr);

    const char* status;
    if (strcmp(hashStr, CERT_PIN_LEAF) == 0 ||
        strcmp(hashStr, CERT_PIN_INTERMEDIATE) == 0 ||
        strcmp(hashStr, CERT_PIN_ROOT) == 0) {
        status = "VALID";
    } else {
        status = "INVALID";
    }

    env->ReleaseStringUTFChars(spkiHash, hashStr);

    // Sign the result
    char payload[256];
    long timestamp = (long)time(nullptr);
    snprintf(payload, sizeof(payload), "%s:%ld", status, timestamp);

    char mac[65];
    generateMAC(payload, mac);

    char result[384];
    snprintf(result, sizeof(result), "%s:%s", payload, mac);

    return env->NewStringUTF(result);
}

// ---------------------------------------------------------------------------
// JNI: Get deobfuscated endpoint URL
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jstring JNICALL
Java_com_termopus_app_security_NativeSecrets_getEndpoint(
        JNIEnv* env, jclass, jstring key) {
    if (g_integrity_token != 0x000000) {
        secureExit();
    }

    const char* keyStr = env->GetStringUTFChars(key, nullptr);
    char result[256];
    memset(result, 0, sizeof(result));

    if (strcmp(keyStr, "relay") == 0) {
        size_t len = sizeof(ENDPOINT_RELAY_OBFUSCATED);
        unsigned char deobfuscated[256];
        deobfuscate(ENDPOINT_RELAY_OBFUSCATED, ENDPOINT_RELAY_MASK_A,
                     ENDPOINT_RELAY_MASK_B, len, deobfuscated,
                     ENDPOINT_RELAY_COEF1, ENDPOINT_RELAY_COEF2);
        memcpy(result, deobfuscated, len);
        result[len] = '\0';
        secureZero(deobfuscated, sizeof(deobfuscated));
    }

    env->ReleaseStringUTFChars(key, keyStr);
    jstring jresult = env->NewStringUTF(result);
    secureZero(result, sizeof(result));
    return jresult;
}

// ---------------------------------------------------------------------------
// JNI: Secure exit — unhookable crash
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT void JNICALL
Java_com_termopus_app_security_NativeSecrets_secureExit(
        JNIEnv*, jclass) {
    secureExit();
}
