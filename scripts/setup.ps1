#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

# Termopus OSS Setup Script (Windows)
# Automates: KV namespace creation, config updates, worker deployment

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir

# ── Helpers ───────────────────────────────────────────────────────
function Write-Info  { param($Msg) Write-Host "[INFO] " -ForegroundColor Cyan -NoNewline; Write-Host $Msg }
function Write-Ok    { param($Msg) Write-Host "[OK] " -ForegroundColor Green -NoNewline; Write-Host $Msg }
function Write-Warn  { param($Msg) Write-Host "[WARN] " -ForegroundColor Yellow -NoNewline; Write-Host $Msg }
function Write-Err   { param($Msg) Write-Host "[ERROR] " -ForegroundColor Red -NoNewline; Write-Host $Msg }

# ── Prerequisites ─────────────────────────────────────────────────
function Test-Prerequisites {
    $missing = @()

    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        $missing += "claude (Claude Code CLI - https://docs.anthropic.com/en/docs/claude-code)"
    }
    if (-not (Get-Command wrangler -ErrorAction SilentlyContinue)) {
        $missing += "wrangler (npm install -g wrangler)"
    }
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        $missing += "npm (https://nodejs.org/)"
    }
    if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
        $missing += "flutter (https://docs.flutter.dev/get-started/install)"
    }
    if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
        $missing += "cargo (https://rustup.rs/) - not needed if using pre-built bridge binary"
    }

    # OpenSSL: check PATH first, then Git for Windows
    $openssl = Get-Command openssl -ErrorAction SilentlyContinue
    if (-not $openssl) {
        $gitOpenssl = "C:\Program Files\Git\usr\bin\openssl.exe"
        if (Test-Path $gitOpenssl) {
            $env:PATH = "C:\Program Files\Git\usr\bin;$env:PATH"
            Write-Warn "Using OpenSSL from Git for Windows"
        } else {
            $missing += "openssl (install Git for Windows, or: winget install ShiningLight.OpenSSL)"
        }
    }

    if ($missing.Count -gt 0) {
        Write-Err "Missing prerequisites:"
        foreach ($m in $missing) {
            Write-Host "  - $m"
        }
        exit 1
    }
    Write-Ok "All prerequisites found"
}

# ── Wrangler Auth ─────────────────────────────────────────────────
function Test-WranglerAuth {
    $whoami = wrangler whoami 2>$null
    if ($whoami -notmatch "Account ID") {
        Write-Warn "Not logged into Wrangler"
        Write-Host "Running: wrangler login"
        wrangler login
    }
    Write-Ok "Wrangler authenticated"
}

# ── Create KV Namespace (idempotent) ──────────────────────────────
function New-KvNamespace {
    param([string]$Name)

    # Check if namespace already exists
    try {
        $json = wrangler kv namespace list 2>$null
        $namespaces = $json | ConvertFrom-Json
        $existing = $namespaces | Where-Object { $_.title -eq $Name } | Select-Object -First 1
        if ($existing) {
            Write-Ok "KV namespace '$Name' already exists: $($existing.id)"
            return $existing.id
        }
    } catch {
        # If list fails or parsing fails, proceed to create
    }

    $output = wrangler kv namespace create $Name 2>&1 | Out-String
    if ($output -match 'id = "([^"]+)"') {
        $nsId = $Matches[1]
        Write-Ok "Created KV namespace '$Name': $nsId"
        return $nsId
    }

    Write-Err "Failed to create KV namespace '$Name'"
    Write-Host $output
    exit 1
}

# ── Update KV ID in wrangler.toml ─────────────────────────────────
function Update-KvId {
    param([string]$File, [string]$Binding, [string]$NewId)

    $lines = Get-Content $File
    $result = @()
    $foundBinding = $false

    foreach ($line in $lines) {
        if ($line -match "binding = `"$Binding`"") {
            $foundBinding = $true
            $result += $line
            continue
        }
        if ($foundBinding -and $line.Trim().StartsWith('id = ')) {
            $result += "id = `"$NewId`""
            $foundBinding = $false
            continue
        }
        $foundBinding = $false
        $result += $line
    }

    Set-Content -Path $File -Value $result -Encoding UTF8
}

# ── Remove custom domain routes ───────────────────────────────────
function Remove-CustomDomainRoutes {
    param([string]$File)

    $content = Get-Content $File -Raw
    $content = [regex]::Replace($content, '\[\[(?:env\.\w+\.)?routes\]\]\r?\npattern = "[^"]*"\r?\ncustom_domain = true\r?\n\r?\n?', '')
    Set-Content -Path $File -Value $content -NoNewline -Encoding UTF8
}

# ── Main ──────────────────────────────────────────────────────────
function Main {
    Write-Host ""
    Write-Host "+===========================================+" -ForegroundColor Cyan
    Write-Host "|       Termopus OSS Setup Script           |" -ForegroundColor Cyan
    Write-Host "+===========================================+" -ForegroundColor Cyan
    Write-Host ""

    Test-Prerequisites
    Test-WranglerAuth

    # ── Create KV Namespaces ──
    Write-Info "Creating KV namespaces..."
    $fcmTokensId = New-KvNamespace "FCM_TOKENS"
    $provisionedDevicesId = New-KvNamespace "PROVISIONED_DEVICES"
    $subscriptionsId = New-KvNamespace "SUBSCRIPTIONS"

    # ── Update relay_worker/wrangler.toml ──
    Write-Info "Updating relay_worker/wrangler.toml..."
    $relayToml = Join-Path $RootDir "relay_worker/wrangler.toml"
    Update-KvId $relayToml "FCM_TOKENS" $fcmTokensId
    Update-KvId $relayToml "PROVISIONED_DEVICES" $provisionedDevicesId
    Update-KvId $relayToml "SUBSCRIPTIONS" $subscriptionsId
    Write-Ok "relay_worker/wrangler.toml updated"

    # ── Update provisioning_api/wrangler.toml ──
    Write-Info "Updating provisioning_api/wrangler.toml..."
    $provToml = Join-Path $RootDir "provisioning_api/wrangler.toml"
    Update-KvId $provToml "PROVISION_KV" $provisionedDevicesId
    Update-KvId $provToml "SUBSCRIPTIONS" $subscriptionsId
    Write-Ok "provisioning_api/wrangler.toml updated"

    # ── Strip placeholder custom domain routes ──
    Write-Info "Removing custom domain routes (using *.workers.dev)..."
    Remove-CustomDomainRoutes $relayToml
    Remove-CustomDomainRoutes $provToml
    Write-Ok "Custom domain routes removed"

    # ── Install dependencies ──
    Write-Info "Installing relay_worker dependencies..."
    Push-Location (Join-Path $RootDir "relay_worker")
    npm install --silent 2>$null
    Pop-Location
    Write-Ok "relay_worker dependencies installed"

    Write-Info "Installing provisioning_api dependencies..."
    Push-Location (Join-Path $RootDir "provisioning_api")
    npm install --silent 2>$null
    Pop-Location
    Write-Ok "provisioning_api dependencies installed"

    # ── Deploy workers ──
    Write-Info "Deploying relay worker (dev)..."
    Push-Location (Join-Path $RootDir "relay_worker")
    $relayOutput = npx wrangler deploy --env dev 2>&1 | Out-String
    Pop-Location
    $relayUrl = ""
    if ($relayOutput -match '(https://[^\s]*\.workers\.dev)') {
        $relayUrl = $Matches[1]
    }
    Write-Ok "Relay worker deployed: $relayUrl"

    Write-Info "Deploying provisioning API (dev)..."
    Push-Location (Join-Path $RootDir "provisioning_api")
    $provOutput = npx wrangler deploy --env dev 2>&1 | Out-String
    Pop-Location
    $provUrl = ""
    if ($provOutput -match '(https://[^\s]*\.workers\.dev)') {
        $provUrl = $Matches[1]
    }
    Write-Ok "Provisioning API deployed: $provUrl"

    # ── Generate CA Certificate ──
    $caDir = Join-Path $RootDir ".ca"
    if (-not (Test-Path $caDir)) { New-Item -ItemType Directory -Path $caDir | Out-Null }

    $caKey = Join-Path $caDir "ca-key.pem"
    $caCert = Join-Path $caDir "ca-cert.pem"

    if ((Test-Path $caKey) -and (Test-Path $caCert)) {
        Write-Ok "CA certificate already exists in $caDir"
    } else {
        Write-Info "Generating EC P-256 CA key pair..."
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 `
            -keyout $caKey -out $caCert `
            -days 3650 -nodes `
            -subj "/CN=Termopus Self-Hosted CA/O=Termopus" 2>$null
        Write-Ok "CA certificate generated"
    }

    # ── Set CA Secrets on Workers ──
    Write-Info "Setting CA_PRIVATE_KEY on provisioning API..."
    Get-Content $caKey -Raw | wrangler secret put CA_PRIVATE_KEY --env dev --config $provToml 2>$null
    Write-Ok "CA_PRIVATE_KEY set"

    Write-Info "Setting CA_CERTIFICATE on provisioning API..."
    Get-Content $caCert -Raw | wrangler secret put CA_CERTIFICATE --env dev --config $provToml 2>$null
    Write-Ok "CA_CERTIFICATE set on provisioning API"

    Write-Info "Setting CA_CERTIFICATE on relay worker..."
    Get-Content $caCert -Raw | wrangler secret put CA_CERTIFICATE --env dev --config $relayToml 2>$null
    Write-Ok "CA_CERTIFICATE set on relay worker"

    # ── Redeploy with Secrets ──
    Write-Info "Redeploying workers with CA secrets..."
    Push-Location (Join-Path $RootDir "relay_worker")
    npx wrangler deploy --env dev 2>$null | Out-Null
    Pop-Location
    Push-Location (Join-Path $RootDir "provisioning_api")
    npx wrangler deploy --env dev 2>$null | Out-Null
    Pop-Location
    Write-Ok "Workers redeployed with mTLS certificates"

    # ── Update app constants ──
    if ($provUrl) {
        Write-Info "Updating app/lib/shared/constants.dart..."
        $constFile = Join-Path $RootDir "app/lib/shared/constants.dart"
        $content = Get-Content $constFile -Raw
        $content = $content -replace 'https://YOUR_PROVISIONING_API_URL', $provUrl
        Set-Content -Path $constFile -Value $content -NoNewline -Encoding UTF8
        Write-Ok "constants.dart updated with provisioning URL"
    }

    # ── Summary ──
    $wsUrl = $relayUrl -replace '^https:', 'wss:'

    Write-Host ""
    Write-Host "+===========================================+" -ForegroundColor Green
    Write-Host "|          Setup Complete!                   |" -ForegroundColor Green
    Write-Host "+===========================================+" -ForegroundColor Green
    Write-Host ""
    Write-Host "Relay Worker:      $relayUrl"
    Write-Host "Provisioning API:  $provUrl"
    Write-Host ""
    Write-Host "Your relay WebSocket URL (save this!):" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  $wsUrl"
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  1. Build the Flutter app:"
    Write-Host "     cd app; flutter pub get; flutter run"
    Write-Host ""
    Write-Host "  2. Run the bridge (pick one):"
    Write-Host ""
    Write-Host "     Option A - Pre-built binary (no Rust needed):"
    Write-Host "       Download from: https://github.com/Termopus/termopus/releases"
    Write-Host "       Run the MSI installer and launch Termopus from the Start Menu."
    Write-Host ""
    Write-Host "       On first launch, you'll be prompted to enter the relay URL above."
    Write-Host "       It's saved automatically - you only enter it once."
    Write-Host ""
    Write-Host "     Option B - Build from source:"
    Write-Host "       cd bridge; cargo build --release"
    Write-Host "       .\target\release\termopus.exe"
    Write-Host ""
    Write-Host "  3. Scan the QR code from the bridge with your phone"
    Write-Host ""
    Write-Host "CA files saved to: $caDir\"
    Write-Host "  - ca-key.pem   (KEEP PRIVATE - do not commit)"
    Write-Host "  - ca-cert.pem  (public, safe to share)"
    Write-Host ""
}

Main
