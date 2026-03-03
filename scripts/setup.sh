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
    # Required for setup.sh to run
    local missing=()
    command -v wrangler >/dev/null 2>&1 || missing+=("wrangler (npm install -g wrangler)")
    command -v npm      >/dev/null 2>&1 || missing+=("npm (https://nodejs.org/)")
    command -v openssl  >/dev/null 2>&1 || missing+=("openssl")

    if [ ${#missing[@]} -gt 0 ]; then
        error "Missing prerequisites (required for setup):"
        for m in "${missing[@]}"; do
            echo "  - $m"
        done
        exit 1
    fi

    # Optional — needed later but not for setup itself
    if ! command -v claude >/dev/null 2>&1; then
        warn "Claude Code not found — install before running the bridge: https://docs.anthropic.com/en/docs/claude-code"
    fi
    if ! command -v flutter >/dev/null 2>&1; then
        warn "Flutter not found — needed to build the mobile app: https://docs.flutter.dev/get-started/install"
    fi
    if ! command -v cargo >/dev/null 2>&1; then
        info "Rust/Cargo not found — not needed if using a pre-built bridge binary from GitHub Releases"
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

    # ── Backend Summary ──
    local ws_url="${relay_url/https:/wss:}"
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║       Backend Deployed!               ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════╝${NC}"
    echo ""
    echo "Relay Worker:      $relay_url"
    echo "Provisioning API:  $prov_url"
    echo ""
    echo -e "${CYAN}Your relay WebSocket URL (save this!):${NC}"
    echo ""
    echo "  $ws_url"
    echo ""
    echo "CA files saved to: $ca_dir/"
    echo "  - ca-key.pem   (KEEP PRIVATE — do not commit)"
    echo "  - ca-cert.pem  (public, safe to share)"
    echo ""

    # ── Bridge Setup ──
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Bridge Setup${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  The bridge runs on your computer alongside Claude Code."
    echo "  How would you like to install it?"
    echo ""
    echo "  1) Download pre-built binary (recommended, no Rust needed)"
    echo "  2) Build from source (requires Rust/Cargo)"
    echo "  3) Skip — I'll set it up later"
    echo ""
    read -r -p "  Choose [1/2/3]: " bridge_choice
    echo ""

    case "$bridge_choice" in
        1)
            install_prebuilt_bridge "$ws_url"
            ;;
        2)
            build_bridge_from_source "$ws_url"
            ;;
        *)
            echo -e "${CYAN}Next steps:${NC}"
            echo ""
            echo "  1. Build the Flutter app:"
            echo "     cd app && flutter pub get && flutter run"
            echo ""
            echo "  2. Install the bridge:"
            echo "     Download from: https://github.com/Termopus/termopus/releases"
            echo "     Or build: cd bridge && cargo build --release"
            echo ""
            echo "     On first launch, you'll be prompted to enter the relay URL:"
            echo "     $ws_url"
            echo ""
            echo "  3. Scan the QR code from the bridge with your phone"
            echo ""
            ;;
    esac
}

# ── Download pre-built bridge ─────────────────────────────────────
install_prebuilt_bridge() {
    local ws_url="$1"
    local os_name
    os_name="$(uname -s)"

    info "Detecting platform..."

    # Determine which asset to download
    local asset_pattern
    case "$os_name" in
        Darwin)
            asset_pattern="macos-arm64.dmg"
            ;;
        Linux)
            asset_pattern="linux-x86_64.tar.gz"
            ;;
        *)
            warn "Unsupported platform for auto-download: $os_name"
            echo "  Download manually from: https://github.com/Termopus/termopus/releases"
            return
            ;;
    esac

    ok "Platform: $os_name"

    # Check if gh CLI is available
    if ! command -v gh >/dev/null 2>&1; then
        warn "GitHub CLI (gh) not found — needed for auto-download"
        echo ""
        echo "  Install it: https://cli.github.com/"
        echo "  Or download manually: https://github.com/Termopus/termopus/releases"
        return
    fi

    info "Downloading latest bridge release..."
    local tmp_dir
    tmp_dir="$(mktemp -d)"

    if ! gh release download --repo Termopus/termopus --pattern "*${asset_pattern}" --dir "$tmp_dir" 2>/dev/null; then
        warn "Download failed — you may need to run: gh auth login"
        echo "  Or download manually: https://github.com/Termopus/termopus/releases"
        rm -rf "$tmp_dir"
        return
    fi

    local downloaded_file
    downloaded_file="$(ls "$tmp_dir"/*"$asset_pattern" 2>/dev/null | head -1)"

    if [ -z "$downloaded_file" ]; then
        warn "No matching release found"
        rm -rf "$tmp_dir"
        return
    fi

    case "$os_name" in
        Darwin)
            ok "Downloaded: $(basename "$downloaded_file")"
            echo ""
            info "Opening DMG — drag Termopus to Applications..."
            open "$downloaded_file"
            echo ""
            echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${GREEN}  Almost done!${NC}"
            echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
            echo "  1. Drag Termopus to your Applications folder"
            echo "  2. Launch Termopus from Applications"
            echo "  3. When prompted, enter your relay URL:"
            echo "     $ws_url"
            echo "  4. Build the Flutter app on your phone:"
            echo "     cd app && flutter pub get && flutter run"
            echo "  5. Scan the QR code from the bridge with your phone"
            echo ""
            ;;
        Linux)
            ok "Downloaded: $(basename "$downloaded_file")"
            local install_dir="$HOME/.local/bin"
            mkdir -p "$install_dir"
            tar -xzf "$downloaded_file" -C "$tmp_dir"
            local extracted_dir
            extracted_dir="$(ls -d "$tmp_dir"/Termopus-* 2>/dev/null | head -1)"
            if [ -n "$extracted_dir" ]; then
                cp "$extracted_dir/termopus" "$install_dir/"
                [ -f "$extracted_dir/termopus-hook" ] && cp "$extracted_dir/termopus-hook" "$install_dir/"
                chmod +x "$install_dir/termopus" "$install_dir/termopus-hook" 2>/dev/null
                ok "Installed to $install_dir/termopus"
            fi
            rm -rf "$tmp_dir"
            echo ""
            echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${GREEN}  Almost done!${NC}"
            echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
            echo "  1. Run the bridge:"
            echo "     $install_dir/termopus"
            echo "  2. When prompted, enter your relay URL:"
            echo "     $ws_url"
            echo "  3. Build the Flutter app on your phone:"
            echo "     cd app && flutter pub get && flutter run"
            echo "  4. Scan the QR code from the bridge with your phone"
            echo ""
            ;;
    esac
}

# ── Build bridge from source ──────────────────────────────────────
build_bridge_from_source() {
    local ws_url="$1"

    if ! command -v cargo >/dev/null 2>&1; then
        error "Rust/Cargo is required to build from source"
        echo "  Install from: https://rustup.rs/"
        echo ""
        echo "  After installing Rust, run:"
        echo "    cd bridge && cargo build --release"
        echo "    ./target/release/termopus"
        return
    fi

    info "Building bridge from source (this may take a few minutes)..."
    if (cd "$ROOT_DIR/bridge" && cargo build --release 2>&1); then
        ok "Bridge built successfully"
        echo ""
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}  Almost done!${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo "  1. Run the bridge:"
        echo "     cd bridge && ./target/release/termopus"
        echo "  2. When prompted, enter your relay URL:"
        echo "     $ws_url"
        echo "  3. Build the Flutter app on your phone:"
        echo "     cd app && flutter pub get && flutter run"
        echo "  4. Scan the QR code from the bridge with your phone"
        echo ""
    else
        error "Build failed — check the output above for errors"
    fi
}

main "$@"
