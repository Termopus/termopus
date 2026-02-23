#!/usr/bin/env bash
set -euo pipefail

# Termopus mTLS Setup Script
# Generates a CA certificate and enables mTLS enforcement

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

echo ""
echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     Termopus mTLS Setup Script        ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
echo ""

# Check openssl
if ! command -v openssl >/dev/null 2>&1; then
    echo -e "${RED}[ERROR]${NC} openssl is required but not found"
    exit 1
fi

# ── Generate CA ───────────────────────────────────────────────────
CA_DIR="$ROOT_DIR/.ca"
mkdir -p "$CA_DIR"

if [ -f "$CA_DIR/ca-key.pem" ] && [ -f "$CA_DIR/ca-cert.pem" ]; then
    warn "CA files already exist in $CA_DIR"
    read -rp "Overwrite? [y/N] " answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        info "Using existing CA files"
    else
        rm -f "$CA_DIR/ca-key.pem" "$CA_DIR/ca-cert.pem"
    fi
fi

if [ ! -f "$CA_DIR/ca-key.pem" ]; then
    info "Generating EC P-256 CA key pair..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$CA_DIR/ca-key.pem" -out "$CA_DIR/ca-cert.pem" \
        -days 3650 -nodes \
        -subj "/CN=Termopus Self-Hosted CA/O=Termopus"
    ok "CA certificate generated"
fi

# ── Set Wrangler Secrets ──────────────────────────────────────────
info "Setting CA_PRIVATE_KEY on provisioning API (dev)..."
wrangler secret put CA_PRIVATE_KEY --env dev < "$CA_DIR/ca-key.pem" \
    --config "$ROOT_DIR/provisioning_api/wrangler.toml"
ok "CA_PRIVATE_KEY set"

info "Setting CA_CERTIFICATE on provisioning API (dev)..."
wrangler secret put CA_CERTIFICATE --env dev < "$CA_DIR/ca-cert.pem" \
    --config "$ROOT_DIR/provisioning_api/wrangler.toml"
ok "CA_CERTIFICATE set on provisioning API"

info "Setting CA_CERTIFICATE on relay worker (dev)..."
wrangler secret put CA_CERTIFICATE --env dev < "$CA_DIR/ca-cert.pem" \
    --config "$ROOT_DIR/relay_worker/wrangler.toml"
ok "CA_CERTIFICATE set on relay worker"

# ── Enable mTLS Enforcement ──────────────────────────────────────
info "Enabling MTLS_ENFORCEMENT in relay_worker/wrangler.toml..."
sed -i.bak 's/MTLS_ENFORCEMENT = "off"/MTLS_ENFORCEMENT = "on"/g' \
    "$ROOT_DIR/relay_worker/wrangler.toml"
rm -f "$ROOT_DIR/relay_worker/wrangler.toml.bak"
ok "MTLS_ENFORCEMENT set to 'on'"

# ── Redeploy ─────────────────────────────────────────────────────
info "Redeploying relay worker (dev)..."
(cd "$ROOT_DIR/relay_worker" && npx wrangler deploy --env dev >/dev/null 2>&1)
ok "Relay worker redeployed"

info "Redeploying provisioning API (dev)..."
(cd "$ROOT_DIR/provisioning_api" && npx wrangler deploy --env dev >/dev/null 2>&1)
ok "Provisioning API redeployed"

# ── Summary ──────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════╗${NC}"
echo -e "${GREEN}║       mTLS Setup Complete!            ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════╝${NC}"
echo ""
echo "CA files saved to: $CA_DIR/"
echo "  - ca-key.pem   (KEEP PRIVATE — do not commit)"
echo "  - ca-cert.pem  (public, safe to share)"
echo ""
echo -e "${YELLOW}IMPORTANT:${NC} If the app was already installed on your phone,"
echo "you MUST uninstall and reinstall it. The old self-signed cert"
echo "from CSR generation is cached in Keychain/Keystore and won't"
echo "match the new CA-signed certificate."
echo ""
echo "  Android: adb uninstall com.termopus.app"
echo "  iOS:     Delete the app from Settings"
echo ""
echo "Then rebuild and run: cd app && flutter run"
echo ""
