import { DurableObject } from 'cloudflare:workers';
import type { Env, Role, ComputerAttachment, PhoneAttachment, WsAttachment, PendingTimeout } from './types';
import { sendPushNotification, type PushResult } from './push';

/**
 * Convert a DER-encoded ECDSA signature to IEEE P1363 format (raw r||s).
 * Both Android (SHA256withECDSA) and iOS (ecdsaSignatureMessageX962SHA256)
 * produce DER-encoded signatures, but Web Crypto API expects P1363.
 *
 * DER format: 0x30 <len> 0x02 <rlen> <r> 0x02 <slen> <s>
 * P1363 format: <r padded to 32 bytes> <s padded to 32 bytes> (64 bytes total for P-256)
 */
function derSignatureToP1363(der: Uint8Array): Uint8Array {
  let offset = 0;

  // SEQUENCE tag
  if (der[offset++] !== 0x30) throw new Error('Expected SEQUENCE tag');
  // Skip SEQUENCE length (may be 1 or 2 bytes)
  let seqLen = der[offset++];
  if (seqLen & 0x80) {
    offset += seqLen & 0x7f; // skip long-form length bytes
  }

  // Read r INTEGER
  if (der[offset++] !== 0x02) throw new Error('Expected INTEGER tag for r');
  const rLen = der[offset++];
  let r = der.slice(offset, offset + rLen);
  offset += rLen;

  // Read s INTEGER
  if (der[offset++] !== 0x02) throw new Error('Expected INTEGER tag for s');
  const sLen = der[offset++];
  let s = der.slice(offset, offset + sLen);

  // Strip leading zero byte (DER sign-padding for positive integers)
  if (r.length === 33 && r[0] === 0) r = r.slice(1);
  if (s.length === 33 && s[0] === 0) s = s.slice(1);

  // Pad to 32 bytes each (P-256 = 256-bit = 32 bytes per component)
  const result = new Uint8Array(64);
  result.set(r, 32 - r.length);
  result.set(s, 64 - s.length);
  return result;
}

/**
 * Minimal ASN.1 DER parser to extract SubjectPublicKeyInfo from an X.509 cert.
 *
 * X.509 structure:
 *   Certificate ::= SEQUENCE {
 *     tbsCertificate TBSCertificate,  -- SEQUENCE
 *     signatureAlgorithm,
 *     signatureValue
 *   }
 *   TBSCertificate ::= SEQUENCE {
 *     version [0] EXPLICIT ...,
 *     serialNumber,
 *     signature AlgorithmIdentifier,
 *     issuer,
 *     validity,
 *     subject,
 *     subjectPublicKeyInfo SEQUENCE, -- THIS IS WHAT WE WANT
 *     ...
 *   }
 */
function extractSPKIFromCert(der: Uint8Array): Uint8Array | null {
  try {
    type TLV = { tag: number; length: number; start: number; end: number };

    // Helper: read tag + length with bounds checking
    function readTLV(pos: number): TLV | null {
      if (pos + 1 >= der.length) return null;
      const tag = der[pos];
      let len = der[pos + 1];
      let start = pos + 2;

      if (len & 0x80) {
        const numBytes = len & 0x7f;
        if (numBytes > 4 || start + numBytes > der.length) return null;
        len = 0;
        for (let i = 0; i < numBytes; i++) {
          len = (len << 8) | der[start + i];
        }
        start += numBytes;
      }

      const end = start + len;
      if (end > der.length) return null;
      return { tag, length: len, start, end };
    }

    // Outer SEQUENCE (Certificate)
    const cert = readTLV(0);
    if (!cert || cert.tag !== 0x30) return null;

    // TBSCertificate SEQUENCE
    const tbs = readTLV(cert.start);
    if (!tbs || tbs.tag !== 0x30) return null;

    // Walk TBSCertificate fields
    let pos = tbs.start;

    // version [0] EXPLICIT (optional)
    let fieldTLV = readTLV(pos);
    if (!fieldTLV) return null;
    if (fieldTLV.tag === 0xa0) {
      pos = fieldTLV.end;
      fieldTLV = readTLV(pos);
      if (!fieldTLV) return null;
    }

    // serialNumber INTEGER
    pos = fieldTLV.end;

    // signature AlgorithmIdentifier SEQUENCE
    fieldTLV = readTLV(pos);
    if (!fieldTLV) return null;
    pos = fieldTLV.end;

    // issuer SEQUENCE
    fieldTLV = readTLV(pos);
    if (!fieldTLV) return null;
    pos = fieldTLV.end;

    // validity SEQUENCE
    fieldTLV = readTLV(pos);
    if (!fieldTLV) return null;
    pos = fieldTLV.end;

    // subject SEQUENCE
    fieldTLV = readTLV(pos);
    if (!fieldTLV) return null;
    pos = fieldTLV.end;

    // subjectPublicKeyInfo SEQUENCE — THIS IS IT
    fieldTLV = readTLV(pos);
    if (!fieldTLV || fieldTLV.tag !== 0x30) return null;

    // Return the entire SPKI TLV (tag + length + content)
    return der.slice(pos, fieldTLV.end);
  } catch (err) {
    console.error('extractSPKIFromCert failed:', err instanceof Error ? err.message : err);
    return null;
  }
}

/**
 * SessionRelay is a Cloudflare Durable Object that bridges WebSocket
 * connections between a computer (bridge agent running Claude Code) and
 * one or more phones (mobile app instances).
 *
 * Design principles:
 *  - The relay is *opaque*: it forwards encrypted blobs without inspecting
 *    their content.  The only plaintext messages it understands are control
 *    messages (e.g. `fcm_register`, `ping`).
 *  - Each session has at most one computer and up to MAX_PHONES phones.
 *  - When all phones are offline and the computer sends a message, the relay
 *    fires a push notification via FCM so the user can re-open the app.
 *  - Permission responses use first-response-wins dedup across multiple phones.
 */
// CRITICAL: Must `extends DurableObject` (not `implements`) and call super()
// for hibernation API to work. `implements` compiles but hibernation silently
// fails — webSocketMessage/webSocketClose/webSocketError never fire.
export class SessionRelay extends DurableObject<Env> {
  // Note: this.ctx and this.env are inherited from DurableObject base class
  // after super(ctx, env). No need to declare them separately.

  /** Rate-limit phone connections per IP (ephemeral, resets on hibernation — acceptable). */
  private phoneConnectAttempts: Map<string, number[]> = new Map();
  private static readonly MAX_PHONE_CONNECTS_PER_MINUTE = 10;

  /** Rate-limit push notifications. */
  private static readonly PUSH_COOLDOWN_MS = 5_000;

  /** Inactivity timeout. */
  private static readonly INACTIVITY_TIMEOUT_MS = 30 * 60 * 1_000;

  /** Dedup TTL. */
  private static readonly DEDUP_TTL_MS = 5 * 60 * 1_000;

  /** Maximum allowed message size (512 KB) to prevent OOM attacks. */
  private static readonly MAX_MESSAGE_SIZE = 512 * 1024;

  /** Alarm interval for cert revocation + maintenance. */
  private static readonly ALARM_INTERVAL_MS = 15 * 60 * 1_000;

  /** Max dedup entries before FIFO eviction. Prevents unbounded storage growth. */
  private static readonly MAX_HANDLED_REQUESTS = 1_000;

  /** Write-through caches (populated on first access, lost on hibernation). */
  private _lastActivity?: number;
  private _handledRequests?: Record<string, number>;
  private _fcmToken?: string | null;  // undefined=unchecked, null=checked-no-token, string=token

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);  // REQUIRED for hibernation — sets this.ctx + this.env
    // Future-proofing: auto ping/pong without waking DO.
    // Currently no client sends app-level JSON `{"type":"ping"}` — phone apps
    // use protocol-level WebSocket pings (OkHttp/URLSession). This is here so
    // if we later add app-level pings, the DO stays hibernated automatically.
    this.ctx.setWebSocketAutoResponse(
      new WebSocketRequestResponsePair('{"type":"ping"}', '{"type":"pong"}')
    );
  }

  /**
   * Log a structured performance entry for each DO wake cycle.
   * Called once at the END of each entry point (fetch, webSocketMessage, alarm, etc.).
   * Outputs a single JSON line per wake — easy to filter in CF logpush/dashboard.
   */
  private logWake(event: string, sessionId: string, startTime: number, extra?: Record<string, unknown>): void {
    const durationMs = Date.now() - startTime;
    console.log(JSON.stringify({
      _tag: 'perf',
      event,
      sessionId: sessionId.slice(0, 12),
      durationMs,
      wsCount: this.ctx.getWebSockets().length,
      ...extra,
    }));
  }

  // ────────────────────────────────────────────────────────────────────
  // WebSocket lookup helpers
  // ────────────────────────────────────────────────────────────────────

  /** Get the computer WebSocket (if connected). */
  private getComputerWs(): WebSocket | undefined {
    const wss = this.ctx.getWebSockets('role:computer');
    return wss.length > 0 ? wss[0] : undefined;
  }

  /** Get a phone WebSocket by deviceId (scans attachments, O(n) where n<=3). */
  private getPhoneByDeviceId(deviceId: string): { ws: WebSocket; attachment: PhoneAttachment } | null {
    for (const ws of this.ctx.getWebSockets('role:phone')) {
      const att = ws.deserializeAttachment() as PhoneAttachment | null;
      if (att && att.deviceId === deviceId) return { ws, attachment: att };
    }
    return null;
  }

  /** Get all phone attachments (for iteration). */
  private getPhoneConnections(): { ws: WebSocket; attachment: PhoneAttachment }[] {
    const result: { ws: WebSocket; attachment: PhoneAttachment }[] = [];
    for (const ws of this.ctx.getWebSockets('role:phone')) {
      const att = ws.deserializeAttachment() as PhoneAttachment | null;
      if (att) result.push({ ws, attachment: att });
    }
    return result;
  }

  /** Count of connected phones. */
  private getPhoneCount(): number {
    return this.ctx.getWebSockets('role:phone').length;
  }

  // ────────────────────────────────────────────────────────────────────
  // Write-through cache + alarm helpers
  // ────────────────────────────────────────────────────────────────────

  private async touchActivity(): Promise<void> {
    const now = Date.now();
    this._lastActivity = now;
    await this.ctx.storage.put('lastActivity', now);
  }

  private async getLastActivity(): Promise<number> {
    if (this._lastActivity !== undefined) return this._lastActivity;
    this._lastActivity = await this.ctx.storage.get<number>('lastActivity') ?? Date.now();
    return this._lastActivity;
  }

  private async getHandledRequests(): Promise<Record<string, number>> {
    if (this._handledRequests !== undefined) return this._handledRequests;
    this._handledRequests = await this.ctx.storage.get<Record<string, number>>('handledRequests') ?? {};
    return this._handledRequests;
  }

  private async markRequestHandled(requestId: string): Promise<void> {
    const handled = await this.getHandledRequests();
    handled[requestId] = Date.now();

    // FIFO eviction: cap at MAX_HANDLED_REQUESTS to prevent unbounded storage growth.
    // Each entry is ~80 bytes (UUID key + timestamp), so 1000 entries ≈ 80KB — well
    // within DO storage limits, but we cap it to be safe.
    const keys = Object.keys(handled);
    if (keys.length > SessionRelay.MAX_HANDLED_REQUESTS) {
      // Sort by timestamp ascending, remove oldest entries
      keys.sort((a, b) => handled[a] - handled[b]);
      const excess = keys.length - SessionRelay.MAX_HANDLED_REQUESTS;
      for (let i = 0; i < excess; i++) {
        delete handled[keys[i]];
      }
    }

    this._handledRequests = handled;
    await this.ctx.storage.put('handledRequests', handled);
  }

  /** Schedule the next alarm at the soonest needed deadline. */
  private async scheduleNextAlarm(pendingTimeouts?: PendingTimeout[]): Promise<void> {
    const now = Date.now();
    const timeouts = pendingTimeouts ?? await this.ctx.storage.get<PendingTimeout[]>('pendingTimeouts') ?? [];

    const candidates: number[] = [];

    // Soonest pending timeout (could be 10s or 30s away)
    for (const t of timeouts) {
      candidates.push(t.deadline);
    }

    // Regular maintenance interval
    candidates.push(now + SessionRelay.ALARM_INTERVAL_MS);

    // Inactivity timeout
    const lastActivity = await this.getLastActivity();
    candidates.push(lastActivity + SessionRelay.INACTIVITY_TIMEOUT_MS);

    // Pick soonest, but at least 1s from now
    const nextAlarm = Math.max(Math.min(...candidates), now + 1_000);

    const currentAlarm = await this.ctx.storage.getAlarm();
    if (currentAlarm === null || currentAlarm > nextAlarm) {
      await this.ctx.storage.setAlarm(nextAlarm);
    }
  }

  /** Add a pending timeout and schedule alarm. */
  private async addPendingTimeout(timeout: PendingTimeout): Promise<void> {
    const timeouts = await this.ctx.storage.get<PendingTimeout[]>('pendingTimeouts') ?? [];
    timeouts.push(timeout);
    await this.ctx.storage.put('pendingTimeouts', timeouts);
    await this.scheduleNextAlarm(timeouts);
  }

  // ────────────────────────────────────────────────────────────────────
  // HTTP / WebSocket upgrade handler
  // ────────────────────────────────────────────────────────────────────

  async fetch(request: Request): Promise<Response> {
    const t0 = Date.now();
    const url = new URL(request.url);
    const role = url.searchParams.get('role') as Role | null;
    const sessionId = url.searchParams.get('sessionId') ?? '';

    // ── Validate role ────────────────────────────────────────────────
    if (!role || (role !== 'computer' && role !== 'phone')) {
      return this.jsonResponse(
        { error: 'Query parameter "role" is required and must be "computer" or "phone"' },
        400,
      );
    }

    // ── Require WebSocket upgrade ────────────────────────────────────
    const upgradeHeader = request.headers.get('Upgrade');
    if (!upgradeHeader || upgradeHeader.toLowerCase() !== 'websocket') {
      return this.jsonResponse(
        { error: 'WebSocket upgrade required. Send an HTTP request with Upgrade: websocket header.' },
        426,
      );
    }

    // ── Phone rate-limit (before WebSocket allocation) ───────────────
    if (role === 'phone') {
      const clientIP = request.headers.get('CF-Connecting-IP') ?? 'unknown';
      const now = Date.now();
      const attempts = this.phoneConnectAttempts.get(clientIP) ?? [];
      const recent = attempts.filter(t => now - t < 60_000);
      if (recent.length >= SessionRelay.MAX_PHONE_CONNECTS_PER_MINUTE) {
        return new Response(null, { status: 429 });
      }
      recent.push(now);
      this.phoneConnectAttempts.set(clientIP, recent);

      // Periodic cleanup
      if (this.phoneConnectAttempts.size > 100) {
        for (const [ip, ts] of this.phoneConnectAttempts) {
          if (ip === clientIP) continue;
          const valid = ts.filter(t => now - t < 60_000);
          if (valid.length === 0) this.phoneConnectAttempts.delete(ip);
        }
      }
    }

    // ── Authenticate the connection ──────────────────────────────────
    const authResult = await this.authenticateConnection(request, role, sessionId);
    if (!authResult.authorized) {
      return this.jsonResponse(
        { error: authResult.reason ?? 'Unauthorized' },
        authResult.statusCode ?? 403,
      );
    }

    // ── Create WebSocket pair ────────────────────────────────────────
    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];

    if (role === 'computer') {
      // Close existing computer connections
      for (const existing of this.ctx.getWebSockets('role:computer')) {
        try { existing.close(1008, 'Replaced by new connection'); } catch (_) {}
      }

      this.ctx.acceptWebSocket(server, ['role:computer']);
      server.serializeAttachment({ role: 'computer', sessionId } satisfies ComputerAttachment);

      // Resend any pending device authorization requests
      const pendingEntries = await this.ctx.storage.list<{ fingerprint: string; deviceId: string; timestamp: number }>({ prefix: 'pendingAuth:' });
      for (const [key, pending] of pendingEntries) {
        const fp = key.slice('pendingAuth:'.length);
        this.safeSend(server, JSON.stringify({
          type: 'device_authorize_request',
          fingerprint: fp,
          timestamp: pending.timestamp,
        }));
        console.log(`[${sessionId}] Resent pending auth request for ${fp}`);
      }
    } else {
      const deviceId = authResult.deviceId ?? `anon-${Date.now()}`;
      const maxPhones = parseInt(this.env.MAX_PHONES_PER_SESSION ?? '3', 10);

      // Close existing connection for same device
      for (const ws of this.ctx.getWebSockets('role:phone')) {
        const att = ws.deserializeAttachment() as PhoneAttachment | null;
        if (att && att.deviceId === deviceId) {
          try { ws.close(1008, 'Replaced by new connection from same device'); } catch (_) {}
        }
      }

      // Evict oldest if at capacity
      const allPhones = this.ctx.getWebSockets('role:phone');
      if (allPhones.length >= maxPhones) {
        let oldestWs: WebSocket | null = null;
        let oldestTime = Infinity;
        for (const ws of allPhones) {
          const att = ws.deserializeAttachment() as PhoneAttachment;
          if (att.connectedAt < oldestTime) { oldestTime = att.connectedAt; oldestWs = ws; }
        }
        if (oldestWs) try { oldestWs.close(1008, 'Oldest connection evicted'); } catch (_) {}
      }

      this.ctx.acceptWebSocket(server, ['role:phone']);

      const enforcement = (this.env.MTLS_ENFORCEMENT ?? 'on').toLowerCase();
      let nonce: string | undefined;

      if (enforcement !== 'off') {
        const nonceBytes = new Uint8Array(32);
        crypto.getRandomValues(nonceBytes);
        nonce = Array.from(nonceBytes).map(b => b.toString(16).padStart(2, '0')).join('');

        this.safeSend(server, JSON.stringify({ type: 'auth_challenge', nonce, timestamp: Date.now() }));

        // Alarm-based auth timeout (replaces setTimeout)
        await this.addPendingTimeout({ type: 'auth_timeout', key: deviceId, deadline: Date.now() + 10_000 });
      }

      server.serializeAttachment({
        role: 'phone', sessionId, deviceId, connectedAt: Date.now(),
        authenticated: enforcement === 'off', sessionAuthorized: enforcement === 'off',
        pendingNonce: nonce,
      } satisfies PhoneAttachment);

      if (enforcement === 'off') {
        // Dev mode: notify peer_connected immediately
        this.notifyPhonePeerConnected(deviceId);
      }

      // Note: trackDeviceSession is called after auth succeeds (in device_auth handler)
      // to avoid writing temporary pending-* deviceIds to KV.
    }

    // Notify peers that a new connection joined.
    // Phone peer_connected is deferred to after auth succeeds (issue I).
    if (role === 'computer') {
      this.broadcastToPhones({ type: 'peer_connected', role: 'computer', timestamp: Date.now() });
    }

    await this.touchActivity();
    await this.scheduleNextAlarm();

    this.logWake('fetch', sessionId, t0, { role });

    return new Response(null, { status: 101, webSocket: client });
  }

  // ────────────────────────────────────────────────────────────────────
  // Hibernatable WebSocket handlers
  // ────────────────────────────────────────────────────────────────────

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const t0 = Date.now();
    const attachment = ws.deserializeAttachment() as WsAttachment;
    if (!attachment) return;

    const role = attachment.role;
    const sessionId = attachment.sessionId;
    const deviceId = role === 'phone' ? (attachment as PhoneAttachment).deviceId : undefined;

    await this.touchActivity();
    await this.handleMessage(ws, role, message, sessionId, deviceId);

    this.logWake('wsMessage', sessionId, t0, {
      role,
      msgSize: typeof message === 'string' ? message.length : message.byteLength,
    });
  }

  async webSocketClose(ws: WebSocket, code: number, reason: string, wasClean: boolean): Promise<void> {
    const t0 = Date.now();
    const attachment = ws.deserializeAttachment() as WsAttachment;
    if (!attachment) return;

    const role = attachment.role;
    const sessionId = attachment.sessionId;
    const deviceId = role === 'phone' ? (attachment as PhoneAttachment).deviceId : undefined;

    // CRITICAL: Must reciprocate the close per CF docs.
    // Failing to call ws.close() causes 1006 abnormal closure errors on clients.
    try { ws.close(code, reason); } catch (_) {}

    await this.handleClose(role, sessionId, code, reason, deviceId);

    this.logWake('wsClose', sessionId, t0, { role, code });
  }

  async webSocketError(ws: WebSocket, error: unknown): Promise<void> {
    const t0 = Date.now();
    const attachment = ws.deserializeAttachment() as WsAttachment;
    if (!attachment) return;

    const role = attachment.role;
    const sessionId = attachment.sessionId;
    const deviceId = role === 'phone' ? (attachment as PhoneAttachment).deviceId : undefined;

    console.error(`WebSocket error for ${role}:`, error);
    await this.handleClose(role, sessionId, 1011, 'WebSocket error', deviceId);

    this.logWake('wsError', sessionId, t0, { role });
  }

  // ────────────────────────────────────────────────────────────────────
  // Alarm handler (unified: timeouts + inactivity + revocation + dedup)
  // ────────────────────────────────────────────────────────────────────

  async alarm(): Promise<void> {
    const t0 = Date.now();
    const now = t0;

    // 1. Process expired timeouts
    const timeouts = await this.ctx.storage.get<PendingTimeout[]>('pendingTimeouts') ?? [];
    const expired = timeouts.filter(t => t.deadline <= now);
    const remaining = timeouts.filter(t => t.deadline > now);

    for (const t of expired) {
      await this.handleExpiredTimeout(t);
    }

    if (remaining.length > 0) {
      await this.ctx.storage.put('pendingTimeouts', remaining);
    } else {
      await this.ctx.storage.delete('pendingTimeouts');
    }

    // 2. Inactivity check
    const lastActivity = await this.getLastActivity();
    if (now - lastActivity >= SessionRelay.INACTIVITY_TIMEOUT_MS) {
      for (const ws of this.ctx.getWebSockets()) {
        try { ws.close(1000, 'Session timed out'); } catch (_) {}
      }
      await this.ctx.storage.deleteAll();
      // No logWake here — session is dead, storage wiped
      return;
    }

    // 3. Cert revocation check (only for sessionAuthorized phones)
    try {
      for (const { ws, attachment } of this.getPhoneConnections()) {
        if (!attachment.sessionAuthorized) continue;
        const certEntry = await this.env.PROVISIONED_DEVICES.get(`cert:${attachment.deviceId}`);
        if (!certEntry) {
          console.log(`[revocation] Cert revoked for ${attachment.deviceId.slice(0, 16)}, disconnecting`);
          try { ws.close(4004, 'Certificate revoked'); } catch (_) {}
          this.safeSend(this.getComputerWs(), JSON.stringify({
            type: 'peer_disconnected',
            role: 'phone',
            deviceId: attachment.deviceId,
            reason: 'certificate_revoked',
            phoneCount: this.getPhoneCount(),
            timestamp: Date.now(),
          }));
        }
      }
    } catch (e) {
      console.error('[revocation] KV check failed, will retry next alarm:', e);
    }

    // 4. Dedup cleanup
    const handled = await this.getHandledRequests();
    const cutoff = now - SessionRelay.DEDUP_TTL_MS;
    let dedupCleaned = 0;
    for (const [id, ts] of Object.entries(handled)) {
      if (ts < cutoff) { delete handled[id]; dedupCleaned++; }
    }
    if (dedupCleaned > 0) {
      this._handledRequests = handled;
      await this.ctx.storage.put('handledRequests', handled);
    }

    // 5. Don't reschedule if no active connections — let DO be evicted naturally
    if (this.ctx.getWebSockets().length === 0) {
      // Still log — useful to see "alarm fired but nobody home"
      this.logWake('alarm', 'unknown', t0, { expiredTimeouts: expired.length, dedupCleaned, noConnections: true });
      return;
    }

    // 6. Reschedule
    await this.scheduleNextAlarm(remaining);

    // Grab any sessionId from a connected WS for the log
    const anyWs = this.ctx.getWebSockets()[0];
    const att = anyWs?.deserializeAttachment() as WsAttachment | null;
    this.logWake('alarm', att?.sessionId ?? 'unknown', t0, {
      expiredTimeouts: expired.length,
      dedupCleaned,
      remainingTimeouts: remaining.length,
    });
  }

  /** Handle an expired timeout (auth or authorization). */
  private async handleExpiredTimeout(timeout: PendingTimeout): Promise<void> {
    if (timeout.type === 'auth_timeout') {
      const phone = this.getPhoneByDeviceId(timeout.key);
      if (phone && !phone.attachment.authenticated && phone.attachment.pendingNonce) {
        console.log(`Auth timeout for ${timeout.key}`);
        this.safeSend(phone.ws, JSON.stringify({
          type: 'auth_result', success: false, reason: 'Authentication timed out',
        }));
        phone.ws.close(4001, 'Authentication timed out');
      }
    } else if (timeout.type === 'authorization_timeout') {
      const stillPending = await this.ctx.storage.get<{ fingerprint: string; deviceId: string; timestamp: number }>(`pendingAuth:${timeout.key}`);
      if (stillPending && (!timeout.requestTimestamp || stillPending.timestamp === timeout.requestTimestamp)) {
        await this.ctx.storage.delete(`pendingAuth:${timeout.key}`);

        const phone = this.getPhoneByDeviceId(timeout.key);
        if (phone && !phone.attachment.sessionAuthorized) {
          this.safeSend(phone.ws, JSON.stringify({
            type: 'session_authorized', success: false, reason: 'Authorization timed out',
          }));
          phone.ws.close(4003, 'Authorization timed out');
        }
      }
    }
  }

  // ────────────────────────────────────────────────────────────────────
  // Message handling
  // ────────────────────────────────────────────────────────────────────

  private async handleMessage(
    senderWs: WebSocket,
    sender: Role,
    data: string | ArrayBuffer,
    sessionId: string,
    senderDeviceId?: string,
  ): Promise<void> {
    // ── Size guard: drop oversized messages to prevent OOM ───────────
    const size = typeof data === 'string' ? data.length : data.byteLength;
    if (size > SessionRelay.MAX_MESSAGE_SIZE) {
      console.error(`[${sessionId}] Message too large: ${size} bytes from ${sender}, dropping`);
      return;
    }

    // ── Try to intercept control messages (plaintext JSON) ───────────
    if (typeof data === 'string') {
      const handled = await this.tryHandleControlMessage(senderWs, sender, data, sessionId, senderDeviceId);
      if (handled) return;
    }

    // ── Forward to peers ─────────────────────────────────────────────
    if (sender === 'computer') {
      // Computer → broadcast to session-authorized phones only
      this.broadcastToPhones(data, true, true);
      if (this.getPhoneCount() === 0) {
        const pushSent = await this.sendPushIfAvailable(sessionId).catch(() => false);
        this.safeSend(this.getComputerWs(), JSON.stringify({
          type: 'peer_offline',
          role: 'phone',
          pushSent: pushSent ?? false,
          timestamp: Date.now(),
        }));
      }
    } else {
      // Gate: reject non-control messages from unauthorized phones
      if (senderDeviceId) {
        const phoneConn = this.getPhoneByDeviceId(senderDeviceId);
        if (phoneConn && (!phoneConn.attachment.authenticated || !phoneConn.attachment.sessionAuthorized)) {
          console.log(`[${sessionId}] Rejecting message from unauthorized phone ${senderDeviceId}`);
          this.safeSend(senderWs, JSON.stringify({
            type: 'error',
            reason: 'not_authorized',
          }));
          return;
        }
      }

      // Phone → forward to computer
      const computerWs = this.getComputerWs();
      if (computerWs) {
        try {
          computerWs.send(data);
        } catch {
          // Notify phone that computer is offline
          this.safeSend(senderWs, JSON.stringify({
            type: 'peer_offline',
            role: 'computer',
            timestamp: Date.now(),
          }));
        }
      } else {
        // Computer is offline: tell the phone
        this.safeSend(senderWs, JSON.stringify({
          type: 'peer_offline',
          role: 'computer',
          timestamp: Date.now(),
        }));
      }
    }
  }

  /**
   * Attempt to parse and handle a control message.
   * Returns `true` if the message was a recognized control message and
   * was fully handled (i.e. should NOT be forwarded to the peer).
   */
  private async tryHandleControlMessage(
    senderWs: WebSocket,
    sender: Role,
    raw: string,
    sessionId: string,
    senderDeviceId?: string,
  ): Promise<boolean> {
    if (raw.length === 0 || (raw[0] !== '{' && raw[0] !== '[')) {
      return false;
    }

    let parsed: Record<string, unknown>;
    try {
      parsed = JSON.parse(raw) as Record<string, unknown>;
    } catch {
      return false;
    }

    const msgType = parsed.type;

    // ── FCM token registration (phone only) ──────────────────────────
    if (msgType === 'fcm_register' && sender === 'phone') {
      // Gate: require authentication before accepting FCM tokens
      const att = senderWs.deserializeAttachment() as PhoneAttachment;
      if (att && !att.authenticated) {
        console.log(`[${sessionId}] Dropping fcm_register from unauthenticated phone ${senderDeviceId}`);
        return true;
      }
      const token = parsed.token;
      if (typeof token === 'string' && token.length > 0) {
        this._fcmToken = token;
        await this.ctx.storage.put('fcmToken', token);
        await this.env.FCM_TOKENS.put(sessionId, token, {
          expirationTtl: 60 * 60 * 24 * 30,
        });
        // Acknowledge back to the sending phone
        this.safeSend(senderWs, JSON.stringify({
          type: 'fcm_registered',
          timestamp: Date.now(),
        }));
      }
      return true;
    }

    // ── Device authentication (phone only) ─────────────────────────
    if (msgType === 'device_auth' && sender === 'phone' && senderDeviceId) {
      const att = senderWs.deserializeAttachment() as PhoneAttachment;
      if (!att || !att.pendingNonce) {
        if (att) {
          this.safeSend(senderWs, JSON.stringify({
            type: 'auth_result', success: false, reason: 'No pending challenge',
          }));
        }
        return true;
      }

      const fingerprint = parsed.fingerprint as string | undefined;
      const signature = parsed.signature as string | undefined;
      const certificate = parsed.certificate as string | undefined;

      if (!fingerprint || !signature || !certificate) {
        this.safeSend(senderWs, JSON.stringify({
          type: 'auth_result', success: false, reason: 'Missing fields',
        }));
        senderWs.close(4001, 'Authentication failed: missing fields');
        return true;
      }

      try {
        const deviceEntry = await this.verifyDeviceAuth(
          att.pendingNonce, fingerprint, signature, certificate, sessionId,
        );

        if (deviceEntry !== null) {
          // Close existing connection for same fingerprint (duplicate device race)
          const existingPhone = this.getPhoneByDeviceId(fingerprint);
          if (existingPhone && existingPhone.ws !== senderWs) {
            try { existingPhone.ws.close(1008, 'Replaced by new connection from same device'); } catch (_) {}
          }

          // Promote connection: update attachment with fingerprint
          const updatedAtt = senderWs.deserializeAttachment() as PhoneAttachment;
          updatedAtt.deviceId = fingerprint;
          updatedAtt.authenticated = true;
          updatedAtt.sessionAuthorized = false;
          updatedAtt.pendingNonce = undefined;
          senderWs.serializeAttachment(updatedAtt);


          // Check session-device allowlist
          const allowlistKey = `session:${sessionId}:authorized_devices`;
          const allowlistRaw = await this.env.PROVISIONED_DEVICES.get(allowlistKey);
          let allowlist: string[] = [];
          if (allowlistRaw) {
            try { allowlist = JSON.parse(allowlistRaw); } catch { allowlist = []; }
          }

          if (allowlist.includes(fingerprint)) {
            // Returning device — auto-authorize
            const autoAtt = senderWs.deserializeAttachment() as PhoneAttachment;
            autoAtt.sessionAuthorized = true;
            senderWs.serializeAttachment(autoAtt);

            this.safeSend(senderWs, JSON.stringify({
              type: 'auth_result', success: true, deviceId: fingerprint, sessionAuthorized: true,
            }));
            this.safeSend(this.getComputerWs(), JSON.stringify({
              type: 'phone_authenticated',
              deviceId: fingerprint,
              phoneCount: this.getPhoneCount(),
              timestamp: Date.now(),
            }));
            // Deferred peer_connected: phone is now authenticated
            this.notifyPhonePeerConnected(fingerprint);

            console.log(`[${sessionId}] Device auto-authorized (in allowlist): ${fingerprint}`);
          } else {
            // New device — request bridge confirmation
            this.safeSend(senderWs, JSON.stringify({
              type: 'auth_result', success: true, deviceId: fingerprint, sessionAuthorized: false,
              message: 'Waiting for bridge authorization...',
            }));

            // Store pending auth request in DO storage
            await this.ctx.storage.put(`pendingAuth:${fingerprint}`, { fingerprint, deviceId: fingerprint, timestamp: Date.now() });

            const computerWs = this.getComputerWs();
            if (computerWs) {
              this.safeSend(computerWs, JSON.stringify({
                type: 'device_authorize_request',
                fingerprint,
                timestamp: Date.now(),
              }));
              console.log(`[${sessionId}] Authorization request sent to bridge for ${fingerprint}`);
            } else {
              console.log(`[${sessionId}] Bridge offline, device ${fingerprint} waiting for authorization`);
            }

            // Alarm-based authorization timeout (replaces setTimeout)
            await this.addPendingTimeout({
              type: 'authorization_timeout',
              key: fingerprint,
              deadline: Date.now() + 30_000,
              requestTimestamp: Date.now(),
            });
          }

        } else {
          this.safeSend(senderWs, JSON.stringify({
            type: 'auth_result', success: false, reason: 'Verification failed',
          }));
          senderWs.close(4001, 'Authentication failed');
        }
      } catch (err) {
        console.error(`[${sessionId}] Device auth error:`, err);
        this.safeSend(senderWs, JSON.stringify({
          type: 'auth_result', success: false, reason: 'Internal error',
        }));
        senderWs.close(4001, 'Authentication error');
        // Also close any promoted connection if fingerprint was set
        if (fingerprint) {
          const promoted = this.getPhoneByDeviceId(fingerprint);
          if (promoted && promoted.ws !== senderWs) {
            try { promoted.ws.close(4001, 'Authentication error'); } catch (_) {}
          }
        }
      }

      return true;
    }

    // ── Device authorization response (bridge only) ──────────────────
    if (msgType === 'device_authorize_response' && sender === 'computer') {
      const fingerprint = parsed.fingerprint;
      const authorized = parsed.authorized;

      if (typeof fingerprint !== 'string' || !fingerprint) return true;
      if (typeof authorized !== 'boolean') return true;

      const pending = await this.ctx.storage.get<{ fingerprint: string; deviceId: string; timestamp: number }>(`pendingAuth:${fingerprint}`);
      if (!pending) {
        console.log(`[${sessionId}] No pending auth request for ${fingerprint}`);
        return true;
      }

      const phone = this.getPhoneByDeviceId(fingerprint);

      if (authorized) {
        // Add to allowlist in KV (persistence for reconnects, not a security gate)
        try {
          const allowlistKey = `session:${sessionId}:authorized_devices`;
          let allowlist: string[] = [];
          const existing = await this.env.PROVISIONED_DEVICES.get(allowlistKey);
          if (existing) {
            try { allowlist = JSON.parse(existing); } catch { allowlist = []; }
          }
          if (!allowlist.includes(fingerprint)) {
            allowlist.push(fingerprint);
          }
          await this.env.PROVISIONED_DEVICES.put(
            allowlistKey,
            JSON.stringify(allowlist),
            { expirationTtl: 60 * 60 * 24 * 30 }, // 30-day TTL (matches session)
          );
        } catch (err) {
          // KV write failed — still authorize in memory (KV is just persistence for reconnects)
          console.error(`[${sessionId}] KV allowlist write failed for ${fingerprint}:`, err);
        }

        await this.ctx.storage.delete(`pendingAuth:${fingerprint}`);

        if (phone) {
          const att = phone.attachment;
          att.sessionAuthorized = true;
          phone.ws.serializeAttachment(att);

          this.safeSend(phone.ws, JSON.stringify({
            type: 'session_authorized', success: true,
          }));

          // Notify bridge that phone is now fully authorized
          this.safeSend(this.getComputerWs(), JSON.stringify({
            type: 'phone_authenticated',
            deviceId: fingerprint,
            phoneCount: this.getPhoneCount(),
            timestamp: Date.now(),
          }));

          // Deferred peer_connected: phone is now authenticated + authorized
          this.notifyPhonePeerConnected(fingerprint);
        }

        console.log(`[${sessionId}] Device authorized by bridge: ${fingerprint}`);
      } else {
        // Bridge denied
        await this.ctx.storage.delete(`pendingAuth:${fingerprint}`);

        if (phone) {
          this.safeSend(phone.ws, JSON.stringify({
            type: 'session_authorized', success: false, reason: 'Bridge denied authorization',
          }));
          phone.ws.close(4003, 'Authorization denied');
        }
        console.log(`[${sessionId}] Device denied by bridge: ${fingerprint}`);
      }

      return true;
    }

    // ── Keepalive (phone-driven, resets inactivity timer) ────────────
    if (msgType === 'keepalive') return true;

    // ── Status query ─────────────────────────────────────────────────
    if (msgType === 'status') {
      const lastActivity = await this.getLastActivity();
      this.safeSend(senderWs, JSON.stringify({
        type: 'status_response',
        computerConnected: !!this.getComputerWs(),
        phoneCount: this.getPhoneCount(),
        lastActivity,
        timestamp: Date.now(),
      }));
      return true;
    }

    // ── First-response-wins dedup for permission responses ───────────
    // When multiple phones are connected, only the first permission
    // response for a given request ID is forwarded to the computer.
    if (sender === 'phone' && typeof parsed.requestId === 'string') {
      const requestId = parsed.requestId;

      const handled = await this.getHandledRequests();
      if (requestId in handled) {
        // This request was already handled by another phone — drop
        console.log(`[${sessionId}] Dedup: dropping duplicate response for request ${requestId} from ${senderDeviceId}`);
        return true; // Consume but don't forward
      }

      // Mark as handled
      await this.markRequestHandled(requestId);

      // Let it fall through to normal forwarding
      return false;
    }

    return false;
  }

  // ────────────────────────────────────────────────────────────────────
  // Connection close handling
  // ────────────────────────────────────────────────────────────────────

  private async handleClose(
    role: Role,
    sessionId: string,
    code: number,
    reason: string,
    deviceId?: string,
  ): Promise<void> {
    console.log(`[${sessionId}] ${role}${deviceId ? `(${deviceId})` : ''} disconnected: code=${code} reason=${reason}`);

    if (role === 'computer') {
      // DO runtime removes closed WS from getWebSockets — no manual cleanup needed
      // Notify all phones
      this.broadcastToPhones({
        type: 'peer_disconnected',
        role: 'computer',
        code,
        reason,
        timestamp: Date.now(),
      });
    } else {
      // Clean up any pending auth request for this device
      if (deviceId) {
        await this.ctx.storage.delete(`pendingAuth:${deviceId}`);
      }
      // DO runtime removes closed WS from getWebSockets — no manual cleanup needed
      // Notify computer
      this.safeSend(this.getComputerWs(), JSON.stringify({
        type: 'peer_disconnected',
        role: 'phone',
        deviceId,
        phoneCount: this.getPhoneCount(),
        code,
        reason,
        timestamp: Date.now(),
      }));
    }
  }

  // ────────────────────────────────────────────────────────────────────
  // Push notifications
  // ────────────────────────────────────────────────────────────────────

  private async sendPushIfAvailable(sessionId: string): Promise<boolean> {
    const now = Date.now();
    const lastPush = await this.ctx.storage.get<number>('lastPushTimestamp') ?? 0;
    if (now - lastPush < SessionRelay.PUSH_COOLDOWN_MS) return false;

    let fcmToken = this._fcmToken;
    if (fcmToken === undefined) {
      fcmToken = await this.ctx.storage.get<string>('fcmToken') ?? undefined;
      if (!fcmToken) {
        fcmToken = (await this.env.FCM_TOKENS.get(sessionId)) ?? undefined;
        if (fcmToken) {
          this._fcmToken = fcmToken;
          await this.ctx.storage.put('fcmToken', fcmToken);
        } else {
          this._fcmToken = null;  // Cache the miss — prevents KV reads on every message
        }
      } else {
        this._fcmToken = fcmToken;
      }
    }
    if (!fcmToken) {
      // Write cooldown even on miss — protects across DO hibernation boundaries
      await this.ctx.storage.put('lastPushTimestamp', now);
      return false;
    }

    await this.ctx.storage.put('lastPushTimestamp', now);

    const pushResult: PushResult = await sendPushNotification(this.env, {
      token: fcmToken,
      data: { type: 'wake', sessionId },
      collapseKey: sessionId,
    });

    if (pushResult === 'unregistered') {
      // Clean up stale FCM token from cache, DO storage, and KV
      this._fcmToken = undefined;
      await this.ctx.storage.delete('fcmToken');
      try { await this.env.FCM_TOKENS.delete(sessionId); } catch { /* KV errors non-fatal */ }
      console.log(`[${sessionId}] Cleaned stale FCM token (UNREGISTERED)`);
      return false;
    }

    if (pushResult === 'error') {
      console.error(`[${sessionId}] Push notification failed`);
      return false;
    }

    return true;
  }

  // ────────────────────────────────────────────────────────────────────
  // Authentication
  // ────────────────────────────────────────────────────────────────────

  private async authenticateConnection(
    request: Request,
    role: Role,
    sessionId: string,
  ): Promise<{ authorized: boolean; reason?: string; statusCode?: number; deviceId?: string }> {
    if (role === 'phone') {
      return this.authenticatePhone(request, sessionId);
    }
    return this.authenticateComputer(request, sessionId);
  }

  private async authenticatePhone(
    request: Request,
    sessionId: string,
  ): Promise<{ authorized: boolean; reason?: string; statusCode?: number; deviceId?: string }> {
    const mtlsEnforcement = (this.env.MTLS_ENFORCEMENT ?? 'on').toLowerCase();
    if (mtlsEnforcement === 'off') {
      return { authorized: true, deviceId: `dev-${Date.now()}` };
    }
    // Always allow the WebSocket to open — actual auth happens via
    // challenge-response over the WebSocket (device_auth control message).
    return { authorized: true, deviceId: `pending-${Date.now()}` };
  }

  /**
   * Verify a device_auth response:
   * 1. Import the public key from the PEM certificate
   * 2. Verify the ECDSA-P256-SHA256 signature over the nonce
   * 3. Compute SHA-256 fingerprint of the DER certificate
   * 4. Check fingerprint against PROVISIONED_DEVICES KV
   *
   * Returns the device entry string from KV on success (for reuse by caller),
   * or null on failure.
   */
  private async verifyDeviceAuth(
    nonce: string,
    fingerprint: string,
    signatureB64: string,
    certificatePEM: string,
    sessionId: string,
  ): Promise<string | null> {
    // 1. Parse PEM → DER
    const pemBody = certificatePEM
      .replace(/-----BEGIN CERTIFICATE-----/g, '')
      .replace(/-----END CERTIFICATE-----/g, '')
      .replace(/\s/g, '');
    const derBytes = Uint8Array.from(atob(pemBody), c => c.charCodeAt(0));

    // 2. Compute SHA-256 fingerprint of DER certificate
    const fingerprintBuf = await crypto.subtle.digest('SHA-256', derBytes);
    const computedFingerprint = Array.from(new Uint8Array(fingerprintBuf))
      .map(b => b.toString(16).padStart(2, '0'))
      .join('');

    // Constant-time comparison to prevent timing side-channels
    if (computedFingerprint.length !== fingerprint.length) {
      console.log(`[${sessionId}] Fingerprint length mismatch`);
      return null;
    }
    let mismatch = 0;
    for (let i = 0; i < computedFingerprint.length; i++) {
      mismatch |= computedFingerprint.charCodeAt(i) ^ fingerprint.charCodeAt(i);
    }
    if (mismatch !== 0) {
      console.log(`[${sessionId}] Fingerprint mismatch: computed=${computedFingerprint}, claimed=${fingerprint}`);
      return null;
    }

    // 3. Check PROVISIONED_DEVICES KV + extract SPKI in parallel
    // (KV lookup and CPU-bound SPKI extraction are independent)
    const spki = extractSPKIFromCert(derBytes);
    if (!spki) {
      console.log(`[${sessionId}] Failed to extract SPKI from certificate`);
      return null;
    }

    // Run KV lookup and key import in parallel (saves 15-40ms)
    const [deviceEntry, publicKey] = await Promise.all([
      this.env.PROVISIONED_DEVICES
        ? this.env.PROVISIONED_DEVICES.get(`cert:${fingerprint}`)
        : Promise.resolve('{}'),
      crypto.subtle.importKey(
        'spki',
        spki,
        { name: 'ECDSA', namedCurve: 'P-256' },
        false,
        ['verify'],
      ),
    ]);

    if (this.env.PROVISIONED_DEVICES && !deviceEntry) {
      console.log(`[${sessionId}] Device not provisioned: ${fingerprint}`);
      return null;
    }

    // 4. Verify signature over the nonce
    // Both Android and iOS produce DER-encoded ECDSA signatures,
    // but Web Crypto expects IEEE P1363 format (raw r||s).
    const nonceBytes = new TextEncoder().encode(nonce);
    const derSignature = Uint8Array.from(atob(signatureB64), c => c.charCodeAt(0));
    const p1363Signature = derSignatureToP1363(derSignature);

    const valid = await crypto.subtle.verify(
      { name: 'ECDSA', hash: 'SHA-256' },
      publicKey,
      p1363Signature,
      nonceBytes,
    );

    if (!valid) {
      console.log(`[${sessionId}] Signature verification failed for ${fingerprint}`);
      return null;
    }

    return deviceEntry ?? '{}';
  }

  private async authenticateComputer(
    request: Request,
    sessionId: string,
  ): Promise<{ authorized: boolean; reason?: string; statusCode?: number; deviceId?: string }> {
    const authHeader = request.headers.get('Authorization');
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      return {
        authorized: false,
        reason: 'Authorization header with Bearer token is required for computer connections.',
        statusCode: 403,
      };
    }

    const token = authHeader.slice('Bearer '.length);
    if (!token || token.length < 16) {
      return { authorized: false, reason: 'Invalid authorization token.', statusCode: 403 };
    }

    let storedToken = await this.env.PROVISIONED_DEVICES.get(`session:${sessionId}:token`);

    // Migration fallback: check old namespace (FCM_TOKENS) for pre-migration sessions
    if (!storedToken && this.env.FCM_TOKENS) {
      storedToken = await this.env.FCM_TOKENS.get(`session:${sessionId}:token`);
      if (storedToken) {
        // Migrate to new namespace
        await this.env.PROVISIONED_DEVICES.put(`session:${sessionId}:token`, storedToken, {
          expirationTtl: 60 * 60 * 24 * 30,
        });
        console.log(`[${sessionId}] Migrated bearer token from FCM_TOKENS to PROVISIONED_DEVICES`);
      }
    }

    if (!storedToken) {
      // First connection for this session — store token
      await this.env.PROVISIONED_DEVICES.put(`session:${sessionId}:token`, token, {
        expirationTtl: 60 * 60 * 24 * 30,
      });
      return { authorized: true };
    }

    // Constant-time comparison
    if (storedToken.length !== token.length) {
      return { authorized: false, reason: 'Invalid session token.', statusCode: 403 };
    }
    const encoder = new TextEncoder();
    const a = encoder.encode(storedToken);
    const b = encoder.encode(token);
    let mismatch = 0;
    for (let i = 0; i < a.length; i++) {
      mismatch |= a[i] ^ b[i];
    }

    if (mismatch !== 0) {
      return { authorized: false, reason: 'Invalid session token.', statusCode: 403 };
    }

    return { authorized: true };
  }



  // ────────────────────────────────────────────────────────────────────
  // Helpers
  // ────────────────────────────────────────────────────────────────────

  /** Get the WebSocket for a sender (computer or specific phone). */
  /** Broadcast a message or object to all connected phones (authenticated-only by default for safety). */
  private broadcastToPhones(
    data: string | ArrayBuffer | Record<string, unknown>,
    authenticatedOnly = true,
    sessionAuthorizedOnly = false,
  ): void {
    const payload = typeof data === 'string' || data instanceof ArrayBuffer ? data : JSON.stringify(data);
    for (const { ws, attachment } of this.getPhoneConnections()) {
      if (authenticatedOnly && !attachment.authenticated) continue;
      if (sessionAuthorizedOnly && !attachment.sessionAuthorized) continue;
      this.safeSend(ws, payload);
    }
  }

  /** Notify bridge and other phones that a phone has connected (post-auth). */
  private notifyPhonePeerConnected(deviceId: string): void {
    const msg = JSON.stringify({
      type: 'peer_connected',
      role: 'phone',
      deviceId,
      phoneCount: this.getPhoneCount(),
      timestamp: Date.now(),
    });
    this.safeSend(this.getComputerWs(), msg);
    for (const { ws, attachment } of this.getPhoneConnections()) {
      if (attachment.deviceId !== deviceId) {
        this.safeSend(ws, msg);
      }
    }
  }

  /** Send data on a WebSocket, swallowing errors if already closed. */
  private safeSend(ws: WebSocket | undefined, data: string | ArrayBuffer): void {
    if (!ws) return;
    try {
      ws.send(data);
    } catch {
      // Connection already closed; ignore.
    }
  }

  /** Convenience helper for JSON error responses from the DO fetch handler. */
  private jsonResponse(body: Record<string, unknown>, status: number): Response {
    return new Response(JSON.stringify(body), {
      status,
      headers: { 'Content-Type': 'application/json' },
    });
  }
}
