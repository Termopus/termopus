# Self-Hosting Guide

This guide walks through deploying Termopus on your own Cloudflare account. The automated setup takes about 5 minutes.

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Cloudflare account | Free tier | [Sign up](https://dash.cloudflare.com/sign-up) |
| Node.js | 18+ | [nodejs.org](https://nodejs.org/) |
| Flutter | 3.11+ | [flutter.dev](https://docs.flutter.dev/get-started/install) |
| Rust | Latest stable | [rustup.rs](https://rustup.rs/) |
| wrangler | Latest | `npm install -g wrangler` |
| OpenSSL | Any | Pre-installed on macOS/Linux |

## Automated Setup

```bash
git clone https://github.com/Termopus/termopus.git
cd termopus
wrangler login
./scripts/setup.sh
```

The script will:
1. Verify all prerequisites are installed
2. Create three KV namespaces: `FCM_TOKENS`, `PROVISIONED_DEVICES`, `SUBSCRIPTIONS`
3. Patch KV namespace IDs into both `wrangler.toml` files
4. Install npm dependencies for both workers
5. Deploy the relay worker and provisioning API to Cloudflare
6. Generate a self-hosted CA certificate (EC P-256, 10-year validity)
7. Set CA secrets (`CA_PRIVATE_KEY` on provisioning API, `CA_CERTIFICATE` on both workers)
8. Redeploy workers with the CA secrets
9. Update `app/lib/shared/constants.dart` with your provisioning API URL
10. Print your relay and provisioning API URLs

## Build & Run

### Mobile App

```bash
cd app
flutter pub get
flutter run        # Connect phone via USB
```

The app will prompt for biometric setup on first launch and provision a device certificate automatically.

### Bridge

```bash
cd bridge
cargo build --release
./target/release/termopus --relay wss://YOUR_RELAY_URL
```

Replace `YOUR_RELAY_URL` with the relay URL printed by `setup.sh` (change `https://` to `wss://`).

The bridge will display a QR code. Scan it with the Termopus app to pair.

## Configuration Reference

### KV Namespaces

Created automatically by `setup.sh`. If you need to configure manually:

| Namespace | Binding | Used By | Purpose |
|-----------|---------|---------|---------|
| `FCM_TOKENS` | `FCM_TOKENS` | Relay | Firebase push notification tokens |
| `PROVISIONED_DEVICES` | `PROVISIONED_DEVICES` (relay) / `PROVISION_KV` (API) | Both | Device certificates, session tokens, authorized devices |
| `SUBSCRIPTIONS` | `SUBSCRIPTIONS` | Both | Reserved for future use |

### Relay Worker Environment

Set in `relay_worker/wrangler.toml` under `[vars]`:

| Variable | Default | Description |
|----------|---------|-------------|
| `MAX_PHONES_PER_SESSION` | `"3"` | Max concurrent phone connections per session |
| `MAX_BRIDGES_PER_DEVICE` | `"5"` | Max sessions per bridge device |
| `SUBSCRIPTION_ENFORCEMENT` | `"off"` | Subscription gating (not used in OSS) |

**Secrets** (set via `wrangler secret put`):

| Secret | Required | Description |
|--------|----------|-------------|
| `CA_CERTIFICATE` | Yes | PEM certificate for verifying device certs |
| `FCM_PROJECT_ID` | No | Firebase project ID (for push notifications) |
| `FCM_SERVICE_ACCOUNT_EMAIL` | No | Firebase service account email (for push notifications) |
| `FCM_SERVICE_ACCOUNT_KEY` | No | Firebase service account private key (for push notifications) |

### Provisioning API Environment

Set in `provisioning_api/wrangler.toml` under `[vars]`:

| Variable | Default (OSS) | Description |
|----------|---------------|-------------|
| `REQUIRE_DEVICE_INTEGRITY` | `"off"` | App Attest (iOS) / Play Integrity (Android) |
| `REQUIRE_KEY_ATTESTATION` | `"off"` | Android hardware key attestation |
| `ALLOW_SIDELOADED` | `"true"` | Allow sideloaded (non-store) apps |
| `ALLOWED_ORIGINS` | Placeholder | CORS origins (set to your domain for production) |

**Secrets** (set via `wrangler secret put`):

| Secret | Required | Description |
|--------|----------|-------------|
| `CA_PRIVATE_KEY` | Yes | PEM private key for signing device certificates |
| `CA_CERTIFICATE` | Yes | PEM certificate (included in signed certs) |

### App Configuration

`app/lib/shared/constants.dart` — updated automatically by `setup.sh`:

| Constant | Description |
|----------|-------------|
| `provisioningApiBase` | Your provisioning API URL |

### Bridge Configuration

The relay URL is passed as a CLI argument:

```bash
./target/release/termopus --relay wss://your-relay.workers.dev
```

## Custom Domains (Optional)

By default, workers deploy to `*.workers.dev` subdomains. To use custom domains:

1. Add your domain to Cloudflare DNS
2. Edit `relay_worker/wrangler.toml`:
   ```toml
   [[routes]]
   pattern = "relay.yourdomain.com"
   custom_domain = true
   ```
3. Edit `provisioning_api/wrangler.toml`:
   ```toml
   [[routes]]
   pattern = "api.yourdomain.com"
   custom_domain = true
   ```
4. Redeploy: `npx wrangler deploy --env dev`

## Push Notifications (Optional)

Push notifications alert your phone when Claude is waiting for input. They require Firebase.

1. Create a Firebase project at [console.firebase.google.com](https://console.firebase.google.com)
2. Replace `app/android/app/google-services.json` with your Firebase config
3. For iOS: add `GoogleService-Info.plist` to `app/ios/Runner/`
4. Set secrets on the relay worker:
   ```bash
   cd relay_worker
   wrangler secret put FCM_PROJECT_ID --env dev
   wrangler secret put FCM_SERVICE_ACCOUNT_EMAIL --env dev
   wrangler secret put FCM_SERVICE_ACCOUNT_KEY --env dev
   ```
5. Redeploy: `npx wrangler deploy --env dev`

## CA Certificate Management

The CA certificate is generated during setup and stored in `.ca/`:
- `ca-key.pem` — **private key** (keep secret, do not commit)
- `ca-cert.pem` — public certificate (safe to share)

### Regenerating the CA

If you need to regenerate:

```bash
./scripts/setup-mtls.sh
```

**Important:** After regenerating the CA, you must **uninstall and reinstall** the app on all devices. The old device certificate was signed by the previous CA and will be rejected.

```bash
# Android
adb uninstall com.termopus.app

# iOS — delete from Settings > General > iPhone Storage
```

Then rebuild: `cd app && flutter run`

### Certificate Lifecycle

- Device certificates are short-lived and auto-expire
- The app automatically renews certificates before they expire
- Re-provisioning is rate-limited per device to prevent abuse

## Updating

Pull the latest code and redeploy:

```bash
git pull origin main

# Redeploy workers
cd relay_worker && npx wrangler deploy --env dev
cd ../provisioning_api && npx wrangler deploy --env dev

# Rebuild app
cd ../app && flutter pub get && flutter run

# Rebuild bridge
cd ../bridge && cargo build --release
```

## Cost

Termopus uses Cloudflare Workers, KV, and Durable Objects. Durable Objects require the **Workers Paid plan** ($5/month). KV and Workers requests for typical personal usage stay well within included limits. Check [Cloudflare's pricing page](https://developers.cloudflare.com/workers/platform/pricing/) for current details.
