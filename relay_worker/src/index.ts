import { SessionRelay } from './relay';
import type { Env } from './types';

// Re-export the Durable Object class so the runtime can instantiate it.
export { SessionRelay };

// Re-export Env for use by other modules that import from this entrypoint.
export type { Env };

/** Minimum length for a valid session ID. */
const MIN_SESSION_ID_LENGTH = 8;

/** Maximum length for a session ID to prevent abuse. */
const MAX_SESSION_ID_LENGTH = 128;

/** Session IDs must be alphanumeric + hyphens + underscores only. */
const SESSION_ID_PATTERN = /^[a-zA-Z0-9_-]+$/;

export default {
  async fetch(
    request: Request,
    env: Env,
    _ctx: ExecutionContext,
  ): Promise<Response> {
    const url = new URL(request.url);

    // ── CORS preflight ───────────────────────────────────────────────
    if (request.method === 'OPTIONS') {
      return handleCORS();
    }

    // ── Health check (public, unauthenticated) ───────────────────────
    if (url.pathname === '/health') {
      return jsonResponse({ status: 'ok', timestamp: new Date().toISOString() }, 200);
    }

    // ── Extract and validate session ID from path ────────────────────
    // Path format: /<sessionId>  (e.g. /abc123def456)
    // Strip leading slash, ignore anything after a second slash or query params.
    const pathSegments = url.pathname.slice(1).split('/');
    const sessionId = pathSegments[0] ?? '';

    if (!sessionId || sessionId.length < MIN_SESSION_ID_LENGTH) {
      return jsonResponse(
        { error: 'Invalid session ID: must be at least 8 characters' },
        400,
      );
    }

    if (sessionId.length > MAX_SESSION_ID_LENGTH) {
      return jsonResponse(
        { error: 'Invalid session ID: exceeds maximum length' },
        400,
      );
    }

    if (!SESSION_ID_PATTERN.test(sessionId)) {
      return jsonResponse(
        { error: 'Invalid session ID: only alphanumeric, hyphens, and underscores allowed' },
        400,
      );
    }

    // ── Route to the session's Durable Object ────────────────────────
    // idFromName ensures the same sessionId always maps to the same DO instance.
    const id = env.SESSIONS.idFromName(sessionId);
    const stub = env.SESSIONS.get(id);

    // Forward the original request, injecting sessionId as a query param
    // so the DO can access it without re-parsing the path.
    const doUrl = new URL(request.url);
    doUrl.searchParams.set('sessionId', sessionId);

    return stub.fetch(new Request(doUrl.toString(), request));
  },
};

/**
 * Respond to CORS preflight requests.
 * In production the relay is behind CF Access (mTLS), so CORS is mainly
 * useful during local development with `wrangler dev`.
 */
function handleCORS(): Response {
  return new Response(null, {
    status: 204,
    headers: {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization, Upgrade, Connection',
      'Access-Control-Max-Age': '86400',
    },
  });
}

/** Convenience helper for JSON error/success responses. */
function jsonResponse(body: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}
