/**
 * Cloudflare Worker environment bindings.
 */
export interface Env {
  /** Durable Object namespace for WebSocket session relay instances. */
  SESSIONS: DurableObjectNamespace;
  /** KV namespace for persisting FCM tokens across DO evictions. */
  FCM_TOKENS: KVNamespace;
  /** KV namespace for provisioned device certificates (shared with provisioning worker). */
  PROVISIONED_DEVICES: KVNamespace;
  /** Firebase Cloud Messaging server key (legacy, deprecated). */
  FCM_SERVER_KEY: string;
  /** FCM v1 API: Google Cloud project ID. */
  FCM_PROJECT_ID: string;
  /** FCM v1 API: Service account email. */
  FCM_SERVICE_ACCOUNT_EMAIL: string;
  /** FCM v1 API: Service account private key (PEM-encoded PKCS#8). */
  FCM_SERVICE_ACCOUNT_KEY: string;
  /**
   * mTLS certificate enforcement for phone connections:
   *  - "off" — allow phones without a valid client certificate (dev only)
   *  - "on"  — require provisioned client certificate (production, default)
   */
  MTLS_ENFORCEMENT?: string;
  /** PEM-encoded CA certificate for verifying device certificates. */
  CA_CERTIFICATE?: string;
  /** Max phones per session (default: 3). */
  MAX_PHONES_PER_SESSION?: string;
  /** Max bridges (sessions) per device (default: 5). */
  MAX_BRIDGES_PER_DEVICE?: string;
}

/** Computer WebSocket attachment (survives hibernation). */
export interface ComputerAttachment {
  role: 'computer';
  sessionId: string;
}

/** Phone WebSocket attachment (survives hibernation). */
export interface PhoneAttachment {
  role: 'phone';
  sessionId: string;
  deviceId: string;
  connectedAt: number;
  authenticated: boolean;
  sessionAuthorized: boolean;
  pendingNonce?: string;
}

/** Union type for any WebSocket attachment. */
export type WsAttachment = ComputerAttachment | PhoneAttachment;

/** Alarm-based timeout (replaces setTimeout, stored in DO storage). */
export interface PendingTimeout {
  type: 'auth_timeout' | 'authorization_timeout';
  key: string;
  deadline: number;
  requestTimestamp?: number;
}

/**
 * The role a connecting client identifies as.
 */
export type Role = 'computer' | 'phone';

/**
 * Data-only payload sent to FCM when the phone is offline.
 */
export interface PushPayload {
  type: string;
  sessionId: string;
}
