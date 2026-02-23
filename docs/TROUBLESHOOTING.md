# Troubleshooting

## Common Issues

### Pairing fails / QR code not working

**Symptoms:** Phone scans QR code but never connects, or connection drops immediately.

**Fixes:**
1. Make sure the bridge is running and shows "Waiting for connection..."
2. Check that the relay URL in the QR code matches your deployed worker
3. Ensure your phone and computer have internet access
4. Try restarting the bridge: `Ctrl+C` and run again

### Authentication failed (code 4001)

**Symptoms:** Phone connects but gets disconnected with "Authentication failed."

**Causes:**
- Phone didn't respond to the auth challenge in time (slow network)
- Device certificate is expired or was never provisioned
- CA certificate was regenerated after the app was installed

**Fixes:**
1. Check your network — the auth handshake must complete promptly
2. If you regenerated the CA, uninstall and reinstall the app:
   ```bash
   # Android
   adb uninstall com.termopus.app
   # iOS — delete from Settings > General > iPhone Storage
   ```
   Then rebuild: `cd app && flutter run`

### Authorization denied (code 4003)

**Symptoms:** Phone authenticates but gets "Authorization denied."

**Causes:**
- The bridge rejected the device (you tapped "Deny" on the bridge)
- The bridge didn't respond in time (bridge was closed or unresponsive)

**Fixes:**
1. Make sure the bridge is running when you connect from a new device
2. Approve the device when the bridge shows the authorization prompt
3. Previously approved devices reconnect automatically — this only affects new devices

### Certificate revoked (code 4004)

**Symptoms:** Phone was working but suddenly gets disconnected with "Certificate revoked."

**Causes:**
- The device certificate entry expired or was removed
- The certificate TTL expired without the app renewing in time

**Fixes:**
1. Force-close and reopen the app — it will re-provision automatically
2. If that doesn't work, uninstall and reinstall the app

### "Device was recently provisioned" (429)

**Symptoms:** App shows a rate limit error during provisioning.

**Cause:** Each device has a cooldown period between provisioning attempts.

**Fix:** Wait for the cooldown to expire, or use a different device for testing.

### WebSocket connection drops repeatedly

**Symptoms:** Phone keeps connecting and disconnecting.

**Causes:**
- Unstable network (WiFi to cellular transitions)
- Relay worker is being redeployed
- Too many connections from the same IP (rate limited)

**Fixes:**
1. Check your network stability
2. The app will auto-reconnect with exponential backoff
3. If you're testing rapidly, wait a minute for the rate limit to reset

### Session expired

**Symptoms:** App shows "Session expired" and can't reconnect.

**Cause:** The relay session timed out due to inactivity (no messages from either side).

**Fix:** Re-pair by scanning a new QR code from the bridge.

### Push notifications not working

**Symptoms:** Phone doesn't get notified when Claude is waiting.

**Causes:**
- Firebase is not configured (push is optional)
- FCM token is stale or unregistered

**Fixes:**
1. Verify Firebase is set up — see [Self-Hosting Guide](SELF-HOSTING.md#push-notifications-optional)
2. Force-close and reopen the app to re-register the FCM token
3. Check that `FCM_PROJECT_ID`, `FCM_SERVICE_ACCOUNT_EMAIL`, and `FCM_SERVICE_ACCOUNT_KEY` secrets are set on the relay worker

### Bridge shows "Invalid session token" (403)

**Symptoms:** Bridge can't connect to the relay.

**Cause:** The session token stored in KV doesn't match. This can happen if another bridge instance connected to the same session.

**Fix:** Only one bridge can be connected per session. Stop other bridge instances and retry.

## Build Issues

### Flutter build fails

```bash
cd app
flutter clean
flutter pub get
flutter run
```

If you get dependency errors, make sure Flutter is version 3.11+:
```bash
flutter --version
flutter upgrade
```

### Rust build fails

```bash
cd bridge
cargo clean
cargo build --release
```

If you get OpenSSL errors on macOS:
```bash
brew install openssl
export OPENSSL_DIR=$(brew --prefix openssl)
cargo build --release
```

### Worker deployment fails

```bash
# Check auth
wrangler whoami

# Re-login if needed
wrangler login

# Deploy with verbose output
npx wrangler deploy --env dev --verbose
```

## Debugging

### Check relay logs

```bash
cd relay_worker
npx wrangler tail --env dev
```

This streams real-time logs from the relay worker, including auth events and errors.

### Check provisioning API logs

```bash
cd provisioning_api
npx wrangler tail --env dev
```

### Verify KV data

```bash
# List provisioned devices
wrangler kv key list --namespace-id YOUR_PROVISIONED_DEVICES_KV_ID
```

### Check CA certificate validity

```bash
openssl x509 -in .ca/ca-cert.pem -enddate -noout
```

## WebSocket Close Code Reference

| Code | Meaning | User Action |
|------|---------|-------------|
| 1000 | Session timed out (inactivity) | Re-pair via QR code |
| 1006 | Abnormal closure (network dropped) | Auto-reconnects |
| 1008 | Connection replaced or evicted | Normal — new connection took over |
| 1011 | Internal WebSocket error | Check relay logs |
| 4001 | Authentication failed | Check cert / reinstall app |
| 4003 | Authorization denied or timed out | Ensure bridge is running, approve device |
| 4004 | Certificate revoked | Reinstall app to re-provision |
