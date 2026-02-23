# Security Policy

## Reporting a Vulnerability

**Do not open a public issue for security vulnerabilities.**

If you discover a security issue in Termopus, please report it responsibly:

1. **Email**: Send details to **security@termopus.com**
2. **Include**:
   - Description of the vulnerability
   - Steps to reproduce
   - Affected component (app, bridge, relay, provisioning API)
   - Impact assessment (if possible)

We will acknowledge your report within **48 hours** and aim to release a fix within **7 days** for critical issues.

## Scope

The following are in scope for security reports:

| Component | Examples |
|-----------|----------|
| **E2E encryption** | Key exchange flaws, plaintext leaks, weak ciphers |
| **mTLS** | Certificate validation bypasses, CA key exposure |
| **Relay worker** | Unauthorized message access, session hijacking |
| **Provisioning API** | Device impersonation, CSR injection |
| **Mobile app** | Biometric bypass, insecure key storage |
| **Bridge** | Unauthorized Claude Code access, command injection |

## Out of Scope

- Denial of service against your own self-hosted deployment
- Social engineering
- Issues in third-party dependencies (report upstream, but let us know)

## Security Architecture

Termopus uses a 7-layer security model. See the [README](README.md#security) for an overview and [docs/MTLS.md](docs/MTLS.md) for mTLS details.

## Disclosure Policy

- We follow coordinated disclosure — please give us reasonable time to fix issues before publishing
- We credit reporters in release notes (unless you prefer anonymity)
