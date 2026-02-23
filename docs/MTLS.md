# mTLS (Mutual TLS) in Termopus

## Overview

mTLS (Layer 5) is a core security layer in Termopus. The relay authenticates
phones via client certificates issued by your CA. This is set up automatically
by `scripts/setup.sh`.

## How It Works

1. **Provisioning API** generates a client certificate signed by your CA
2. Phone stores the certificate in Keychain/Keystore
3. When connecting to the relay, the phone receives an `auth_challenge` (random nonce)
4. Phone signs the nonce with its private key and sends back the signature + certificate
5. Relay verifies the certificate fingerprint exists in `PROVISIONED_DEVICES` KV
6. Relay verifies the signature using the certificate's public key

## Setup

mTLS is configured automatically during initial setup (`scripts/setup.sh`).
To regenerate certificates or reconfigure manually, see below.

### Re-setup (standalone)

```bash
./scripts/setup-mtls.sh
```

### Manual

#### 1. Generate CA Certificate

```bash
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout ca-key.pem -out ca-cert.pem -days 3650 -nodes \
  -subj "/CN=Termopus Self-Hosted CA/O=Termopus"
```

#### 2. Set Wrangler Secrets

```bash
# Provisioning API needs both key and cert to sign device certificates
wrangler secret put CA_PRIVATE_KEY --env dev < ca-key.pem
wrangler secret put CA_CERTIFICATE --env dev < ca-cert.pem

# Relay needs the cert to verify device certificates
wrangler secret put CA_CERTIFICATE --env dev < ca-cert.pem
```

Run these in both `provisioning_api/` and `relay_worker/` directories respectively.

#### 3. Redeploy

```bash
cd relay_worker && npm run deploy:dev
cd ../provisioning_api && npm run deploy:dev
```

## App Reinstall Requirement

If you regenerate your CA **after** the app has already been installed and provisioned:

1. The app has a self-signed certificate from the initial CSR key generation
2. This certificate is NOT signed by your CA
3. The relay will reject it (fingerprint not in `PROVISIONED_DEVICES` KV)
4. You get `Authentication failed (code 4001)`

**Fix:** Uninstall and reinstall the app so it provisions a fresh certificate
signed by your CA.

```bash
# Android
adb uninstall com.termopus.app

# iOS
# Delete from Settings > General > iPhone Storage
```

Then rebuild and run: `cd app && flutter run`

## Security Note

Keep `ca-key.pem` private. Anyone with the CA key can issue valid client
certificates. The `.ca/` directory is gitignored by default.
