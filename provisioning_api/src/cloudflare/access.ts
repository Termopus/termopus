// ---------------------------------------------------------------------------
// Cloudflare Access mTLS Certificate Management
//
// Integrates with the Cloudflare Access API to register and revoke client
// certificates used for mTLS authentication.
//
// When a device is provisioned, its signed client certificate is registered
// with Cloudflare Access so the relay worker can enforce mTLS.  When a
// device is compromised or decommissioned, the certificate is revoked
// (deleted) from Access.
//
// API Reference:
//   https://developers.cloudflare.com/api/operations/access-mtls-authentication-add-an-mtls-certificate
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface RegisterCertParams {
  /** Cloudflare account ID. */
  accountId: string;
  /** CF Access service token client ID. */
  clientId: string;
  /** CF Access service token client secret. */
  clientSecret: string;
  /** PEM-encoded client certificate to register. */
  certificate: string;
  /** Human-readable name for the certificate (e.g. "device-abc123"). */
  name: string;
}

export interface RevokeCertParams {
  /** Cloudflare account ID. */
  accountId: string;
  /** CF Access service token client ID. */
  clientId: string;
  /** CF Access service token client secret. */
  clientSecret: string;
  /** Name of the certificate to revoke. */
  name: string;
}

/** Shape of a certificate entry in the Cloudflare Access API response. */
interface AccessCertificate {
  id: string;
  name: string;
  fingerprint: string;
  associated_hostnames: string[];
  created_at: string;
  updated_at: string;
  expires_on: string;
}

/** Standard Cloudflare v4 API response envelope. */
interface CloudflareAPIResponse<T> {
  success: boolean;
  errors: Array<{ code: number; message: string }>;
  messages: string[];
  result: T;
  result_info?: {
    page: number;
    per_page: number;
    count: number;
    total_count: number;
  };
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const CF_API_BASE = 'https://api.cloudflare.com/client/v4';

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Register a client certificate with Cloudflare Access.
 *
 * POSTs the PEM certificate to the Access mTLS certificates endpoint.
 * On success, the certificate is immediately trusted by Access policies
 * that require client certificate authentication.
 *
 * Returns `true` on success, `false` on failure.
 */
export async function registerCertWithAccess(params: RegisterCertParams): Promise<boolean> {
  const url = `${CF_API_BASE}/accounts/${params.accountId}/access/certificates`;

  try {
    const response = await fetch(url, {
      method: 'POST',
      headers: buildHeaders(params.clientId, params.clientSecret),
      body: JSON.stringify({
        name: params.name,
        certificate: params.certificate,
      }),
    });

    if (!response.ok) {
      const errorBody = await response.text();
      console.error(
        `CF Access register certificate failed (HTTP ${response.status}):`,
        errorBody,
      );

      // Handle duplicate name gracefully — the device may be re-provisioning
      if (response.status === 409) {
        console.log(
          `Certificate "${params.name}" already exists. Attempting update...`,
        );
        return await updateExistingCert(params);
      }

      return false;
    }

    const data = await response.json() as CloudflareAPIResponse<AccessCertificate>;
    if (!data.success) {
      console.error('CF Access register returned errors:', data.errors);
      return false;
    }

    console.log(
      `Certificate registered with CF Access: name="${params.name}", id="${data.result.id}"`,
    );
    return true;
  } catch (error) {
    console.error('CF Access register exception:', error);
    return false;
  }
}

/**
 * Revoke (delete) a client certificate from Cloudflare Access.
 *
 * Finds the certificate by name, then deletes it.  After deletion the
 * device can no longer authenticate via mTLS to Access-protected origins.
 *
 * Returns `true` if the certificate was deleted or does not exist.
 * Returns `false` on API errors.
 */
export async function revokeCertFromAccess(params: RevokeCertParams): Promise<boolean> {
  try {
    // ---- 1. List certificates to find the one matching the name -----------
    const cert = await findCertByName(
      params.accountId,
      params.clientId,
      params.clientSecret,
      params.name,
    );

    if (!cert) {
      // Certificate not found — treat as already revoked
      console.log(`Certificate "${params.name}" not found — nothing to revoke`);
      return true;
    }

    // ---- 2. Delete the certificate ----------------------------------------
    const deleteUrl =
      `${CF_API_BASE}/accounts/${params.accountId}/access/certificates/${cert.id}`;

    const deleteResponse = await fetch(deleteUrl, {
      method: 'DELETE',
      headers: buildHeaders(params.clientId, params.clientSecret),
    });

    if (!deleteResponse.ok) {
      const errorBody = await deleteResponse.text();
      console.error(
        `CF Access delete certificate failed (HTTP ${deleteResponse.status}):`,
        errorBody,
      );
      return false;
    }

    const deleteData = await deleteResponse.json() as CloudflareAPIResponse<{ id: string }>;
    if (!deleteData.success) {
      console.error('CF Access delete returned errors:', deleteData.errors);
      return false;
    }

    console.log(
      `Certificate revoked from CF Access: name="${params.name}", id="${cert.id}"`,
    );
    return true;
  } catch (error) {
    console.error('CF Access revoke exception:', error);
    return false;
  }
}

// ---------------------------------------------------------------------------
// Internal Helpers
// ---------------------------------------------------------------------------

/**
 * Build standard headers for Cloudflare Access API calls.
 *
 * Uses service token authentication (CF-Access-Client-Id / Secret) rather
 * than API tokens, because the provisioning worker itself is a machine
 * client operating on behalf of the system.
 */
function buildHeaders(clientId: string, clientSecret: string): Record<string, string> {
  return {
    'CF-Access-Client-Id': clientId,
    'CF-Access-Client-Secret': clientSecret,
    'Content-Type': 'application/json',
  };
}

/**
 * Find a certificate by name using paginated listing.
 *
 * Cloudflare paginates certificate lists at 25 per page by default.
 * We iterate all pages to find a match.
 */
async function findCertByName(
  accountId: string,
  clientId: string,
  clientSecret: string,
  name: string,
): Promise<AccessCertificate | null> {
  let page = 1;
  const perPage = 50;

  while (true) {
    const url =
      `${CF_API_BASE}/accounts/${accountId}/access/certificates?page=${page}&per_page=${perPage}`;

    const response = await fetch(url, {
      headers: buildHeaders(clientId, clientSecret),
    });

    if (!response.ok) {
      console.error(
        `CF Access list certificates failed (HTTP ${response.status}):`,
        await response.text(),
      );
      return null;
    }

    const data = await response.json() as CloudflareAPIResponse<AccessCertificate[]>;
    if (!data.success) {
      console.error('CF Access list returned errors:', data.errors);
      return null;
    }

    const match = data.result.find((c) => c.name === name);
    if (match) {
      return match;
    }

    // Check if there are more pages
    const resultInfo = data.result_info;
    if (!resultInfo || page * perPage >= resultInfo.total_count) {
      break;
    }
    page++;
  }

  return null;
}

/**
 * Update an existing certificate (delete old, register new).
 *
 * Used when a device re-provisions and a certificate with the same name
 * already exists in Cloudflare Access.
 */
async function updateExistingCert(params: RegisterCertParams): Promise<boolean> {
  // Find the existing cert
  const existingCert = await findCertByName(
    params.accountId,
    params.clientId,
    params.clientSecret,
    params.name,
  );

  if (!existingCert) {
    console.error('Could not find existing certificate to update');
    return false;
  }

  // Delete the old one
  const deleteUrl =
    `${CF_API_BASE}/accounts/${params.accountId}/access/certificates/${existingCert.id}`;

  const deleteResponse = await fetch(deleteUrl, {
    method: 'DELETE',
    headers: buildHeaders(params.clientId, params.clientSecret),
  });

  if (!deleteResponse.ok) {
    console.error(
      'Failed to delete existing certificate for update:',
      await deleteResponse.text(),
    );
    return false;
  }

  // Register the new one
  const registerUrl =
    `${CF_API_BASE}/accounts/${params.accountId}/access/certificates`;

  const registerResponse = await fetch(registerUrl, {
    method: 'POST',
    headers: buildHeaders(params.clientId, params.clientSecret),
    body: JSON.stringify({
      name: params.name,
      certificate: params.certificate,
    }),
  });

  if (!registerResponse.ok) {
    console.error(
      'Failed to register replacement certificate:',
      await registerResponse.text(),
    );
    return false;
  }

  const data = await registerResponse.json() as CloudflareAPIResponse<AccessCertificate>;
  if (!data.success) {
    console.error('Replacement registration errors:', data.errors);
    return false;
  }

  console.log(
    `Certificate updated in CF Access: name="${params.name}", new id="${data.result.id}"`,
  );
  return true;
}
