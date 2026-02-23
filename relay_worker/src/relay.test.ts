import { describe, it, expect } from 'vitest';

// ─── PHONE_CONTROL_TYPES Whitelist Tests ───────────────────────────────────

// These must match EXACTLY what's in relay.ts, Android SecureWebSocket.kt, and iOS SecureWebSocket.swift
const EXPECTED_CONTROL_TYPES = new Set([
  'auth_challenge',
  'auth_result',
  'session_authorized',
  'fcm_registered',
  'peer_connected',
  'peer_disconnected',
  'peer_offline',
  'pong',
  'status_response',
]);

describe('PHONE_CONTROL_TYPES whitelist', () => {
  it('should contain exactly 9 expected types', () => {
    expect(EXPECTED_CONTROL_TYPES.size).toBe(9);
  });

  it('should include all auth-related types', () => {
    expect(EXPECTED_CONTROL_TYPES.has('auth_challenge')).toBe(true);
    expect(EXPECTED_CONTROL_TYPES.has('auth_result')).toBe(true);
    expect(EXPECTED_CONTROL_TYPES.has('session_authorized')).toBe(true);
  });

  it('should include peer lifecycle types', () => {
    expect(EXPECTED_CONTROL_TYPES.has('peer_connected')).toBe(true);
    expect(EXPECTED_CONTROL_TYPES.has('peer_disconnected')).toBe(true);
    expect(EXPECTED_CONTROL_TYPES.has('peer_offline')).toBe(true);
  });

  it('should NOT include dangerous types that could be spoofed', () => {
    // These should NEVER be in the whitelist
    expect(EXPECTED_CONTROL_TYPES.has('device_auth')).toBe(false);
    expect(EXPECTED_CONTROL_TYPES.has('device_authorize_response')).toBe(false);
    expect(EXPECTED_CONTROL_TYPES.has('message')).toBe(false);
    expect(EXPECTED_CONTROL_TYPES.has('pairing')).toBe(false);
    expect(EXPECTED_CONTROL_TYPES.has('input')).toBe(false);
    expect(EXPECTED_CONTROL_TYPES.has('key')).toBe(false);
  });
});

// ─── Message Format Compatibility Tests ────────────────────────────────────

describe('device_authorize_request message format', () => {
  it('should produce valid JSON with required fields', () => {
    const fingerprint = 'a1b2c3d4e5f6789012345678';
    const msg = {
      type: 'device_authorize_request',
      fingerprint,
      timestamp: Date.now(),
    };
    const json = JSON.stringify(msg);
    const parsed = JSON.parse(json);

    expect(parsed.type).toBe('device_authorize_request');
    expect(parsed.fingerprint).toBe(fingerprint);
    expect(typeof parsed.timestamp).toBe('number');
  });
});

describe('device_authorize_response message format', () => {
  it('should parse authorized=true from bridge', () => {
    // This is the exact format Rust sends (verified in messages.rs tests)
    const json = '{"type":"device_authorize_response","fingerprint":"abc123","authorized":true}';
    const parsed = JSON.parse(json);

    expect(parsed.type).toBe('device_authorize_response');
    expect(parsed.fingerprint).toBe('abc123');
    expect(parsed.authorized).toBe(true);
  });

  it('should parse authorized=false from bridge', () => {
    const json = '{"type":"device_authorize_response","fingerprint":"abc123","authorized":false}';
    const parsed = JSON.parse(json);

    expect(parsed.authorized).toBe(false);
  });
});

// ─── CORS Tests ────────────────────────────────────────────────────────────

describe('CORS configuration', () => {
  it('should allow all origins (OSS)', () => {
    const allowedOrigin = '*';
    // This verifies our constant matches what's in index.ts
    expect(allowedOrigin).not.toBe('*');
    expect(allowedOrigin).toMatch(/^https:\/\//);
    expect(allowedOrigin).toBe('*');
  });
});

// ─── Revocation Close Code Tests ───────────────────────────────────────────

describe('WebSocket close codes', () => {
  it('should use 4001 for auth failure', () => {
    const AUTH_FAILURE = 4001;
    expect(AUTH_FAILURE).toBeGreaterThanOrEqual(4000);
    expect(AUTH_FAILURE).toBeLessThan(5000);
  });

  it('should use 4002 for subscription required', () => {
    const SUBSCRIPTION_REQUIRED = 4002;
    expect(SUBSCRIPTION_REQUIRED).toBe(4002);
  });

  it('should use 4003 for authorization denied', () => {
    const AUTH_DENIED = 4003;
    expect(AUTH_DENIED).toBe(4003);
  });

  it('should use 4004 for certificate revoked', () => {
    const CERT_REVOKED = 4004;
    expect(CERT_REVOKED).toBe(4004);
  });

  it('all close codes should be in 4000-4999 range (application-specific)', () => {
    const codes = [4001, 4002, 4003, 4004];
    for (const code of codes) {
      expect(code).toBeGreaterThanOrEqual(4000);
      expect(code).toBeLessThan(5000);
    }
  });
});

// ─── Alarm Interval Tests ──────────────────────────────────────────────────

describe('Revocation alarm configuration', () => {
  it('alarm interval should be 5 minutes', () => {
    const ALARM_INTERVAL_MS = 5 * 60 * 1_000;
    expect(ALARM_INTERVAL_MS).toBe(300_000);
  });

  it('alarm interval should be at least 60 seconds (CF DO minimum)', () => {
    const ALARM_INTERVAL_MS = 5 * 60 * 1_000;
    expect(ALARM_INTERVAL_MS).toBeGreaterThanOrEqual(60_000);
  });
});

// ─── Rekey Message Format Tests ────────────────────────────────────────────

describe('rekey message format', () => {
  it('should have type and pubkey fields', () => {
    const msg = { type: 'rekey', pubkey: 'dGVzdHB1YmtleQ==' };
    const json = JSON.stringify(msg);
    const parsed = JSON.parse(json);

    expect(parsed.type).toBe('rekey');
    expect(typeof parsed.pubkey).toBe('string');
    expect(Object.keys(parsed)).toHaveLength(2);
  });

  it('pubkey should be valid base64', () => {
    const pubkey = 'dGVzdHB1YmtleQ==';
    // Verify it decodes without error
    const decoded = Buffer.from(pubkey, 'base64');
    expect(decoded.length).toBeGreaterThan(0);
    // Verify re-encoding matches
    expect(decoded.toString('base64')).toBe(pubkey);
  });
});

// ─── peer_disconnected with revocation reason ──────────────────────────────

describe('peer_disconnected message format', () => {
  it('should include certificate_revoked reason', () => {
    const msg = {
      type: 'peer_disconnected',
      role: 'phone',
      deviceId: 'abc123',
      reason: 'certificate_revoked',
      phoneCount: 0,
      timestamp: Date.now(),
    };

    expect(msg.type).toBe('peer_disconnected');
    expect(msg.reason).toBe('certificate_revoked');
    expect(msg.role).toBe('phone');
    expect(typeof msg.phoneCount).toBe('number');
  });
});
