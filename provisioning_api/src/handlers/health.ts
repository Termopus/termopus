/**
 * Health check handler.
 *
 * Returns a simple 200 OK response with service metadata.
 * Used by monitoring, load balancers, and deployment checks.
 */
export function handleHealth(): Response {
  return new Response(
    JSON.stringify({
      status: 'ok',
      service: 'claude-remote-provisioning',
      timestamp: new Date().toISOString(),
    }),
    {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    },
  );
}
