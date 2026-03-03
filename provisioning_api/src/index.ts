import { handleProvision } from './handlers/provision';
import { handleChallenge } from './handlers/challenge';
import { handleRevoke } from './handlers/revoke';
import { handleHealth } from './handlers/health';
import { handleRenew } from './handlers/renew';

export interface Env {
  // Vars (set in wrangler.toml)
  APPLE_APP_ID: string;
  APPLE_TEAM_ID: string;
  ANDROID_PACKAGE_NAME: string;
  ALLOWED_ORIGINS: string;
  /** Require MEETS_DEVICE_INTEGRITY minimum: off | log | on */
  REQUIRE_DEVICE_INTEGRITY?: string;
  /** Require Android Key Attestation chain: off | log | on */
  REQUIRE_KEY_ATTESTATION?: string;
  /** When "true", allow sideloaded/debug APKs to skip cert digest check */
  ALLOW_SIDELOADED?: string;
  /** Device provisioning cooldown in seconds (default: 3600 = 1 hour) */
  DEVICE_COOLDOWN_SECONDS?: string;

  // Secrets (set via `wrangler secret put`)
  CA_PRIVATE_KEY: string;
  CA_CERTIFICATE: string;
  CF_ACCOUNT_ID: string;
  CF_ACCESS_CLIENT_ID: string;
  CF_ACCESS_CLIENT_SECRET: string;
  GOOGLE_PLAY_INTEGRITY_KEY: string;
  ANDROID_CERTIFICATE_DIGESTS: string;
  ADMIN_API_TOKEN: string;
  /** Service account email for Google API OAuth2 (shared with FCM). */
  FCM_SERVICE_ACCOUNT_EMAIL: string;
  /** Service account PEM private key for Google API OAuth2 (shared with FCM). */
  FCM_SERVICE_ACCOUNT_KEY: string;

  // KV namespaces
  PROVISION_KV: KVNamespace;
}

/** Build CORS headers based on the request origin and allowed origins. */
function buildCorsHeaders(request: Request, env: Env): Record<string, string> {
  const origin = request.headers.get('Origin') ?? '';
  const allowedOrigins = env.ALLOWED_ORIGINS
    ? env.ALLOWED_ORIGINS.split(',').map((o) => o.trim())
    : [];

  // For mobile apps, Origin header is typically absent or non-standard.
  // Allow the request if no Origin is set (native mobile) or if it matches.
  const allowOrigin =
    !origin || allowedOrigins.length === 0 || allowedOrigins.includes(origin)
      ? origin || '*'
      : '';

  if (!allowOrigin) {
    return {};
  }

  return {
    'Access-Control-Allow-Origin': allowOrigin,
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    'Access-Control-Max-Age': '86400',
    ...(allowOrigin !== '*' ? { Vary: 'Origin' } : {}),
  };
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    // CORS preflight
    if (request.method === 'OPTIONS') {
      return handleCORS(request, env);
    }

    // Route requests
    try {
      let response: Response;

      switch (url.pathname) {
        case '/provision/health':
          if (request.method !== 'GET') {
            return methodNotAllowed(request, env);
          }
          response = handleHealth();
          break;

        case '/provision/challenge':
          if (request.method !== 'POST') {
            return methodNotAllowed(request, env);
          }
          response = await handleChallenge(request, env);
          break;

        case '/provision/cert':
          if (request.method !== 'POST') {
            return methodNotAllowed(request, env);
          }
          response = await handleProvision(request, env);
          break;

        case '/provision/revoke':
          if (request.method !== 'POST') {
            return methodNotAllowed(request, env);
          }
          response = await handleRevoke(request, env);
          break;


        case '/provision/renew':
          if (request.method !== 'POST') {
            return methodNotAllowed(request, env);
          }
          response = await handleRenew(request, env);
          break;


        default:
          return notFound(request, env);
      }

      // Attach CORS headers to all successful responses
      return addCORSHeaders(response, request, env);
    } catch (error) {
      console.error('Unhandled error in request handler:', error);
      const message = error instanceof Error ? error.message : 'Internal server error';
      return serverError(message, request, env);
    }
  },
};

function handleCORS(request: Request, env: Env): Response {
  return new Response(null, {
    status: 204,
    headers: buildCorsHeaders(request, env),
  });
}

function addCORSHeaders(response: Response, request: Request, env: Env): Response {
  const corsHeaders = buildCorsHeaders(request, env);
  if (Object.keys(corsHeaders).length === 0) {
    return response;
  }
  const newResponse = new Response(response.body, response);
  for (const [key, value] of Object.entries(corsHeaders)) {
    newResponse.headers.set(key, value);
  }
  return newResponse;
}

function methodNotAllowed(request: Request, env: Env): Response {
  return new Response(
    JSON.stringify({ error: 'Method not allowed' }),
    {
      status: 405,
      headers: {
        'Content-Type': 'application/json',
        'Allow': 'POST, OPTIONS',
        ...buildCorsHeaders(request, env),
      },
    },
  );
}

function notFound(request: Request, env: Env): Response {
  return new Response(
    JSON.stringify({ error: 'Not found' }),
    {
      status: 404,
      headers: { 'Content-Type': 'application/json', ...buildCorsHeaders(request, env) },
    },
  );
}

function serverError(message: string, request: Request, env: Env): Response {
  return new Response(
    JSON.stringify({ error: message }),
    {
      status: 500,
      headers: { 'Content-Type': 'application/json', ...buildCorsHeaders(request, env) },
    },
  );
}
