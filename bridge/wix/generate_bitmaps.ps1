# Generate WiX installer branding bitmaps for Termopus
# Banner: 493x58  (top strip on progress dialogs)
# Dialog: 493x312 (background on welcome/finish dialogs)
#
# IMPORTANT: WiX overlays its own text in the upper portion of dialog.bmp,
# so all branding must go in the bottom ~100px to avoid overlap.

Add-Type -AssemblyName System.Drawing

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ── Banner (493 x 58) ─────────────────────────────────────────────────
# Clean white strip with product name - shown on progress pages
$banner = New-Object System.Drawing.Bitmap(493, 58)
$g = [System.Drawing.Graphics]::FromImage($banner)
$g.SmoothingMode     = 'HighQuality'
$g.TextRenderingHint = 'ClearTypeGridFit'

$g.Clear([System.Drawing.Color]::White)

# Purple accent line at bottom
$g.FillRectangle(
    (New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(120, 70, 200))),
    0, 55, 493, 3)

# Product name
$fontName = New-Object System.Drawing.Font("Segoe UI Semibold", 14)
$g.DrawString("Termopus", $fontName, [System.Drawing.Brushes]::Black, 16, 6)

# Tagline
$fontTag = New-Object System.Drawing.Font("Segoe UI", 9)
$grayBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(100, 100, 100))
$g.DrawString("Remote control for Claude Code", $fontTag, $grayBrush, 18, 32)

$g.Dispose()
$banner.Save((Join-Path $scriptDir "banner.bmp"), [System.Drawing.Imaging.ImageFormat]::Bmp)
$banner.Dispose()
Write-Host "Created banner.bmp (493x58)"

# ── Dialog (493 x 312) ────────────────────────────────────────────────
# WiX overlays title + description text in the top ~200px.
# We keep the top clean and put branding at the bottom.
$dialog = New-Object System.Drawing.Bitmap(493, 312)
$g = [System.Drawing.Graphics]::FromImage($dialog)
$g.SmoothingMode     = 'HighQuality'
$g.TextRenderingHint = 'ClearTypeGridFit'

# White background (matches the WiX dialog text area)
$g.Clear([System.Drawing.Color]::White)

# Purple branded strip at the bottom (y=220 to y=312)
$stripTop = 220
$stripBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
    (New-Object System.Drawing.Point(0, $stripTop)),
    (New-Object System.Drawing.Point(0, 312)),
    [System.Drawing.Color]::FromArgb(55, 30, 100),
    [System.Drawing.Color]::FromArgb(30, 15, 60)
)
$g.FillRectangle($stripBrush, 0, $stripTop, 493, 92)
$stripBrush.Dispose()

# Thin accent line at top of the strip
$g.FillRectangle(
    (New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(140, 90, 220))),
    0, $stripTop, 493, 2)

# "Termopus" brand name in the strip
$sf = New-Object System.Drawing.StringFormat
$sf.Alignment = 'Center'

$fontBrand = New-Object System.Drawing.Font("Segoe UI", 20, [System.Drawing.FontStyle]::Bold)
$whiteBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
$g.DrawString("Termopus", $fontBrand, $whiteBrush,
    (New-Object System.Drawing.RectangleF(0, 228, 493, 35)), $sf)

# Tagline
$fontSub = New-Object System.Drawing.Font("Segoe UI", 9)
$lightBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(190, 190, 210))
$g.DrawString("End-to-End Encrypted  |  iOS & Android  |  Open Source", $fontSub, $lightBrush,
    (New-Object System.Drawing.RectangleF(0, 268, 493, 20)), $sf)

# URL
$fontUrl = New-Object System.Drawing.Font("Segoe UI", 8)
$dimBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(150, 150, 175))
$g.DrawString("termopus.com", $fontUrl, $dimBrush,
    (New-Object System.Drawing.RectangleF(0, 292, 493, 18)), $sf)

$g.Dispose()
$dialog.Save((Join-Path $scriptDir "dialog.bmp"), [System.Drawing.Imaging.ImageFormat]::Bmp)
$dialog.Dispose()
Write-Host "Created dialog.bmp (493x312)"

Write-Host "`nDone!"
