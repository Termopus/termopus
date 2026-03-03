#!/usr/bin/env bash
set -euo pipefail

# Termopus OSS Setup Script
# Automates: KV namespace creation, config updates, worker deployment

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Prerequisites ──────────────────────────────────────────────────
check_prereqs() {
    local missing=()
    command -v claude   >/dev/null 2>&1 || missing+=("claude (Claude Code CLI — https://docs.anthropic.com/en/docs/claude-code)")
    command -v wrangler >/dev/null 2>&1 || missing+=("wrangler (npm install -g wrangler)")
    command -v npm      >/dev/null 2>&1 || missing+=("npm")
    command -v flutter  >/dev/null 2>&1 || missing+=("flutter (https://docs.flutter.dev/get-started/install)")
    command -v cargo    >/dev/null 2>&1 || missing+=("cargo (https://rustup.rs/) — not needed if using pre-built bridge binary")
    command -v openssl  >/dev/null 2>&1 || missing+=("openssl")

    if [ ${#missing[@]} -gt 0 ]; then
        error "Missing prerequisites:"
        for m in "${missing[@]}"; do
            echo "  - $m"
        done
        exit 1
    fi
    ok "All prerequisites found"
}

# ── Wrangler Auth ──────────────────────────────────────────────────
check_wrangler_auth() {
    if ! wrangler whoami 2>/dev/null | grep -q "Account ID"; then
        warn "Not logged into Wrangler"
        echo "Running: wrangler login"
        wrangler login
    fi
    ok "Wrangler authenticated"
}

# ── Create KV Namespace (idempotent) ──────────────────────────────
create_kv_namespace() {
    local name="$1"
    local existing_id

    # Check if namespace already exists
    existing_id=$(wrangler kv namespace list 2>/dev/null | \
        python3 -c "import sys,json; ns=json.load(sys.stdin); print(next((n['id'] for n in ns if n['title']=='$name'), ''))" 2>/dev/null || echo "")

    if [ -n "$existing_id" ]; then
        ok "KV namespace '$name' already exists: $existing_id" >&2
        echo "$existing_id"
        return
    fi

    local output
    output=$(wrangler kv namespace create "$name" 2>&1)
    local ns_id
    ns_id=$(echo "$output" | sed -n 's/.*id = "\([^"]*\)".*/\1/p' | head -1)

    if [ -z "$ns_id" ]; then
        error "Failed to create KV namespace '$name'"
        echo "$output"
        exit 1
    fi

    ok "Created KV namespace '$name': $ns_id" >&2
    echo "$ns_id"
}

# ── Update KV ID in wrangler.toml ─────────────────────────────────
update_kv_id() {
    local file="$1"
    local binding="$2"
    local new_id="$3"

    # Find the line with binding = "BINDING" and update the next id = line
    python3 -c "
import re, sys
with open('$file', 'r') as f:
    lines = f.readlines()
result = []
found_binding = False
for line in lines:
    if 'binding = \"$binding\"' in line:
        found_binding = True
        result.append(line)
        continue
    if found_binding and line.strip().startswith('id = '):
        result.append('id = \"$new_id\"\n')
        found_binding = False
        continue
    found_binding = False
    result.append(line)
with open('$file', 'w') as f:
    f.writelines(result)
"
}

# ── Remove custom domain routes (use *.workers.dev instead) ───────
strip_custom_domain_routes() {
    local file="$1"
    python3 -c "
import re
with open('$file', 'r') as f:
    content = f.read()
# Remove [[routes]] and [[env.*.routes]] blocks (pattern + custom_domain lines)
content = re.sub(r'\[\[(?:env\.\w+\.)?routes\]\]\npattern = \"[^\"]*\"\ncustom_domain = true\n\n?', '', content)
with open('$file', 'w') as f:
    f.write(content)
"
}

# ── Main ───────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       Termopus OSS Setup Script       ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    check_prereqs
    check_wrangler_auth

    # ── Create KV Namespaces ──
    info "Creating KV namespaces..."
    FCM_TOKENS_ID=$(create_kv_namespace "FCM_TOKENS")
    PROVISIONED_DEVICES_ID=$(create_kv_namespace "PROVISIONED_DEVICES")
    SUBSCRIPTIONS_ID=$(create_kv_namespace "SUBSCRIPTIONS")

    # ── Update relay_worker/wrangler.toml ──
    info "Updating relay_worker/wrangler.toml..."
    local relay_toml="$ROOT_DIR/relay_worker/wrangler.toml"
    update_kv_id "$relay_toml" "FCM_TOKENS" "$FCM_TOKENS_ID"
    update_kv_id "$relay_toml" "PROVISIONED_DEVICES" "$PROVISIONED_DEVICES_ID"
    update_kv_id "$relay_toml" "SUBSCRIPTIONS" "$SUBSCRIPTIONS_ID"
    ok "relay_worker/wrangler.toml updated"

    # ── Update provisioning_api/wrangler.toml ──
    info "Updating provisioning_api/wrangler.toml..."
    local prov_toml="$ROOT_DIR/provisioning_api/wrangler.toml"
    update_kv_id "$prov_toml" "PROVISION_KV" "$PROVISIONED_DEVICES_ID"
    update_kv_id "$prov_toml" "SUBSCRIPTIONS" "$SUBSCRIPTIONS_ID"
    ok "provisioning_api/wrangler.toml updated"

    # ── Strip placeholder custom domain routes (deploy to *.workers.dev) ──
    info "Removing custom domain routes (using *.workers.dev)..."
    strip_custom_domain_routes "$relay_toml"
    strip_custom_domain_routes "$prov_toml"
    ok "Custom domain routes removed"

    # ── Install dependencies ──
    info "Installing relay_worker dependencies..."
    (cd "$ROOT_DIR/relay_worker" && npm install --silent)
    ok "relay_worker dependencies installed"

    info "Installing provisioning_api dependencies..."
    (cd "$ROOT_DIR/provisioning_api" && npm install --silent)
    ok "provisioning_api dependencies installed"

    # ── Deploy workers ──
    info "Deploying relay worker (dev)..."
    local relay_output
    relay_output=$(cd "$ROOT_DIR/relay_worker" && npx wrangler deploy --env dev 2>&1)
    local relay_url
    relay_url=$(echo "$relay_output" | sed -n 's|.*\(https://[^ ]*\.workers\.dev\).*|\1|p' | head -1)
    ok "Relay worker deployed: $relay_url"

    info "Deploying provisioning API (dev)..."
    local prov_output
    prov_output=$(cd "$ROOT_DIR/provisioning_api" && npx wrangler deploy --env dev 2>&1)
    local prov_url
    prov_url=$(echo "$prov_output" | sed -n 's|.*\(https://[^ ]*\.workers\.dev\).*|\1|p' | head -1)
    ok "Provisioning API deployed: $prov_url"

    # ── Generate CA Certificate (mTLS is mandatory for OSS) ──
    local ca_dir="$ROOT_DIR/.ca"
    mkdir -p "$ca_dir"

    if [ -f "$ca_dir/ca-key.pem" ] && [ -f "$ca_dir/ca-cert.pem" ]; then
        ok "CA certificate already exists in $ca_dir"
    else
        info "Generating EC P-256 CA key pair..."
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -keyout "$ca_dir/ca-key.pem" -out "$ca_dir/ca-cert.pem" \
            -days 3650 -nodes \
            -subj "/CN=Termopus Self-Hosted CA/O=Termopus" 2>/dev/null
        ok "CA certificate generated"
    fi

    # ── Set CA Secrets on Workers ──
    info "Setting CA_PRIVATE_KEY on provisioning API..."
    wrangler secret put CA_PRIVATE_KEY --env dev < "$ca_dir/ca-key.pem" \
        --config "$ROOT_DIR/provisioning_api/wrangler.toml" 2>/dev/null
    ok "CA_PRIVATE_KEY set"

    info "Setting CA_CERTIFICATE on provisioning API..."
    wrangler secret put CA_CERTIFICATE --env dev < "$ca_dir/ca-cert.pem" \
        --config "$ROOT_DIR/provisioning_api/wrangler.toml" 2>/dev/null
    ok "CA_CERTIFICATE set on provisioning API"

    info "Setting CA_CERTIFICATE on relay worker..."
    wrangler secret put CA_CERTIFICATE --env dev < "$ca_dir/ca-cert.pem" \
        --config "$ROOT_DIR/relay_worker/wrangler.toml" 2>/dev/null
    ok "CA_CERTIFICATE set on relay worker"

    # ── Redeploy with Secrets ──
    info "Redeploying workers with CA secrets..."
    (cd "$ROOT_DIR/relay_worker" && npx wrangler deploy --env dev >/dev/null 2>&1)
    (cd "$ROOT_DIR/provisioning_api" && npx wrangler deploy --env dev >/dev/null 2>&1)
    ok "Workers redeployed with mTLS certificates"

    # ── Update app constants ──
    if [ -n "$prov_url" ]; then
        info "Updating app/lib/shared/constants.dart..."
        sed -i.bak "s|https://YOUR_PROVISIONING_API_URL|$prov_url|g" \
            "$ROOT_DIR/app/lib/shared/constants.dart"
        rm -f "$ROOT_DIR/app/lib/shared/constants.dart.bak"
        ok "constants.dart updated with provisioning URL"
    fi

    # ── Summary ──
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║          Setup Complete!              ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════╝${NC}"
    echo ""
    echo "Relay Worker:      $relay_url"
    echo "Provisioning API:  $prov_url"
    echo ""
    local ws_url="${relay_url/https:/wss:}"

    echo -e "${CYAN}Your relay WebSocket URL (save this!):${NC}"
    echo ""
    echo "  $ws_url"
    echo ""
    echo -e "${CYAN}Next steps:${NC}"
    echo ""
    echo "  1. Build the Flutter app:"
    echo "     cd app && flutter pub get && flutter run"
    echo ""
    echo "  2. Run the bridge (pick one):"
    echo ""
    echo "     Option A — Pre-built binary (no Rust needed):"
    echo "       Download from: https://github.com/Termopus/termopus/releases"
    echo "       macOS:   Open the DMG, drag to Applications, and launch."
    echo "       Windows: Run the MSI installer and launch from Start Menu."
    echo "       Linux:   tar -xzf Termopus-*.tar.gz && ./Termopus-*/termopus"
    echo ""
    echo "       On first launch, you'll be prompted to enter the relay URL above."
    echo "       It's saved automatically — you only enter it once."
    echo ""
    echo "     Option B — Build from source:"
    echo "       cd bridge && cargo build --release"
    echo "       ./target/release/termopus"
    echo ""
    echo "  3. Scan the QR code from the bridge with your phone"
    echo ""
    echo "CA files saved to: $ca_dir/"
    echo "  - ca-key.pem   (KEEP PRIVATE — do not commit)"
    echo "  - ca-cert.pem  (public, safe to share)"
    echo ""
}

main "$@"
