#ifndef NativeSecrets_h
#define NativeSecrets_h

#include <stddef.h>

// Security result signing (returns "STATUS:details:timestamp:hmac")
// Caller MUST call NativeSecrets_freeResult() on the returned pointer.
char* NativeSecrets_signSecurityResult(const char* status);

// Enforcement — validates MAC + freshness, calls __builtin_trap() if tampered.
// Does NOT return a value on failure. On success, returns normally.
void NativeSecrets_enforceSecurityResult(const char* signedResult);

// Certificate pin verification (returns MAC-signed result)
// Caller MUST call NativeSecrets_freeResult() on the returned pointer.
char* NativeSecrets_verifyCertificatePin(const char* spkiHash);

// Endpoint retrieval (returns deobfuscated URL)
// Caller MUST call NativeSecrets_freeResult() on the returned pointer.
char* NativeSecrets_getEndpoint(const char* key);

// Free a result string returned by NativeSecrets functions
void NativeSecrets_freeResult(char* result);

// Unhookable crash via __builtin_trap()
void NativeSecrets_secureExit(void) __attribute__((noreturn));

#endif
