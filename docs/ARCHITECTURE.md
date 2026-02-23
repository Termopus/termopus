# Architecture

## Overview

Termopus has four components that work together to let you control Claude Code from your phone:

```
PHONE                        CLOUDFLARE                       COMPUTER
─────                        ──────────                       ────────
Flutter App                                                  Claude Code
    ↓                                                            ↑
Native WS  ←── WebSocket ──→  Relay DO  ←── WebSocket ──→  Bridge (Rust)
    ↓                         (opaque)                          ↓
Encrypt(msg)                                              Decrypt(msg)
```

All app-level data is **end-to-end encrypted** — the relay only forwards opaque binary blobs. Connection lifecycle messages (authentication, presence, keepalives) are handled by the relay in plaintext.

## Components

### Bridge (Rust)

The bridge runs on your computer alongside Claude Code. It:

- Connects to the relay via WebSocket with a Bearer token
- Generates an ephemeral ECDH keypair for key exchange
- Displays a QR code containing the relay URL, session ID, and public key
- Encrypts all outgoing messages with AES-256-GCM
- Spawns Claude Code as a child process and pipes I/O
- Handles reconnection with preserved crypto state; supports rekeying for forward secrecy

### Relay (Cloudflare Durable Object)

The relay is a stateful WebSocket forwarder. Each session gets its own Durable Object instance. It:

- Tags connections by role: `computer` (max 1) or `phone` (configurable limit)
- Authenticates phones via mTLS challenge-response (see [MTLS.md](MTLS.md))
- Manages device authorization (bridge approves/denies new devices)
- Forwards encrypted binary messages between phone and bridge
- Sends push notifications when the bridge sends a message but no phones are connected
- Runs alarm-based maintenance: auth timeouts, cert revocation checks, request deduplication

**Message routing rules:**
- Computer → all session-authorized phones (broadcast)
- Phone → computer (unicast)
- If no phones online → `peer_offline` back to computer + push notification

**Close codes:**

| Code | Meaning |
|------|---------|
| 4001 | Authentication failed |
| 4003 | Authorization denied or timed out |
| 4004 | Certificate revoked |
| 1008 | Connection replaced or evicted |
| 1011 | Internal WebSocket error |
| 1000 | Session timed out (inactivity) |

### Provisioning API (Cloudflare Worker)

Handles device onboarding. When a phone provisions for the first time:

1. Phone requests a challenge (random nonce)
2. Phone generates a keypair in Secure Enclave / StrongBox
3. Phone creates a CSR (Certificate Signing Request) signed by the private key
4. API verifies: CSR signature, deviceId = SHA-256(public key), optional attestation
5. API signs the CSR with the self-hosted CA, producing a short-lived client certificate
6. Certificate fingerprint is registered in KV with an auto-expiring TTL
7. Phone stores the certificate in Keychain / Keystore

**Environment flags (OSS defaults):**
- `REQUIRE_DEVICE_INTEGRITY = "off"` — skip App Attest / Play Integrity
- `REQUIRE_KEY_ATTESTATION = "off"` — skip Android hardware key attestation
- `ALLOW_SIDELOADED = "true"` — allow sideloaded apps

### Phone App (Flutter)

The Flutter app handles UI and delegates all cryptography to native code (Swift / Kotlin). No cryptographic material ever touches Dart.

**Native bridge capabilities:**
- Biometric authentication (Face ID / fingerprint) with HMAC-signed proof
- ECDH key exchange via Secure Enclave / StrongBox
- AES-256-GCM encryption/decryption
- CSR generation with hardware-backed keys
- Certificate storage in Keychain / Keystore

**Connection states:** `disconnected`, `connecting`, `connected`, `reconnecting`, `error`, `sessionExpired`

Auto-retry with exponential backoff on transient errors. Permanent errors (invalid cert, auth failed, expired session) are not retried.

## Encryption Protocol

### Key Exchange (Pairing)

1. Bridge generates ephemeral P-256 keypair
2. Bridge encodes `{relay_url, session_id, public_key}` in QR code
3. Phone scans QR, generates its own P-256 keypair in Secure Enclave
4. Both compute shared secret via ECDH
5. Shared secret is derived via HKDF-SHA-256 into AES-256-GCM key

### Message Encryption

Every message (both directions) is encrypted as:
```
[nonce (12 bytes)] [ciphertext] [tag (16 bytes)]
```

Sent as binary WebSocket frames. The relay forwards these opaque blobs without inspection.

### Rekeying

The bridge and phone can renegotiate keys by exchanging new ephemeral keypairs and deriving a fresh shared secret, providing forward secrecy.

## Data Storage

### Durable Object (Persistent)

Each session's DO instance persists the following to storage:
- Last activity timestamp — for inactivity timeout
- Request deduplication table
- Cached push notification tokens
- Pending auth/authorization deadlines

Storage is wiped when a session times out due to inactivity.

### KV Namespaces (Persistent)

**PROVISIONED_DEVICES:**
- Device certificate metadata (auto-expiring TTL)
- Authorized devices per session
- Bridge authentication tokens

**FCM_TOKENS:**
- Push notification tokens per session

## Message Types

### Control Messages (Plaintext JSON)

Used for connection lifecycle — not encrypted:
- `auth_challenge` / `device_auth` / `auth_result` — mTLS authentication
- `device_authorize_request` / `device_authorize_response` — new device approval
- `peer_connected` / `peer_disconnected` / `peer_offline` — presence
- `session_authorized` — bridge approved this device
- `keepalive` / `ping` / `pong` — connection health
- `fcm_register` / `fcm_registered` — push notification setup

### Encrypted Messages (Binary)

All app-level communication — encrypted end-to-end:
- `ActionResponse` — approve/deny file edits
- `Text` / `RawInput` / `Key` — user input
- `Command` / `SetModel` / `Config` — Claude Code directives
- `FileTransfer*` — file streaming (start, chunk, complete, ack, cancel)
- `HttpTunnel*` — HTTP tunnel proxy (open, close, request, response)
