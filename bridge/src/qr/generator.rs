use anyhow::{Context, Result};
use image::{Rgba, RgbaImage};
use qrcode::render::unicode;
use qrcode::{EcLevel, QrCode};

/// Termopus logo embedded at compile time for QR branding.
const LOGO_PNG: &[u8] = include_bytes!("../../../assets/logo_square.png");

/// Linear interpolation between two values.
fn lerp(a: f64, b: f64, t: f64) -> f64 {
    a + (b - a) * t
}

/// Check if a point (px, py) falls inside a rounded rectangle of size (w, h)
/// with corner radius r. Point is relative to the rectangle's top-left.
fn is_inside_rounded_rect(px: f64, py: f64, w: f64, h: f64, r: f64) -> bool {
    if px < 0.0 || py < 0.0 || px >= w || py >= h {
        return false;
    }
    let (cx, cy) = if px < r && py < r {
        (r, r)
    } else if px >= w - r && py < r {
        (w - r, r)
    } else if px < r && py >= h - r {
        (r, h - r)
    } else if px >= w - r && py >= h - r {
        (w - r, h - r)
    } else {
        return true;
    };
    let dx = px - cx;
    let dy = py - cy;
    dx * dx + dy * dy <= r * r
}

/// Compute radial gradient color for a module at pixel center (mod_cx, mod_cy).
/// Gradient: deep cyan RGB(40,120,220) at center -> deep purple RGB(100,40,160) at edges.
fn gradient_color(mod_cx: f64, mod_cy: f64, center: f64, max_dist: f64) -> Rgba<u8> {
    let dx = mod_cx - center;
    let dy = mod_cy - center;
    let dist = (dx * dx + dy * dy).sqrt();
    let t = (dist / max_dist).min(1.0);
    let r = lerp(40.0, 100.0, t) as u8;
    let g = lerp(120.0, 40.0, t) as u8;
    let b = lerp(220.0, 160.0, t) as u8;
    Rgba([r, g, b, 255])
}

/// QR code generation for the pairing flow.
///
/// Generates QR codes containing session information (relay URL, session ID,
/// public key) that the phone app scans to initiate pairing.
pub struct QrGenerator;

impl QrGenerator {
    /// Generate a QR code from a data string.
    ///
    /// The data is typically a JSON object containing pairing information:
    /// ```json
    /// {
    ///   "v": 1,
    ///   "relay": "wss://relay.example.com",
    ///   "session": "abc123...",
    ///   "pubkey": "base64...",
    ///   "exp": 1700000000
    /// }
    /// ```
    pub fn generate(data: &str) -> Result<QrImage> {
        let code = QrCode::with_error_correction_level(data.as_bytes(), EcLevel::H)
            .context("Failed to generate QR code from data")?;

        Ok(QrImage { code, data: data.to_string() })
    }

    /// Generate a branded QR code as a 600x600 RGBA image.
    ///
    /// Features: HIGH error correction (30%), rounded modules with radial
    /// gradient (cyan center -> purple edges), centered Termopus logo with
    /// circular white background.
    pub fn generate_branded(data: &str) -> Result<RgbaImage> {
        const IMAGE_SIZE: u32 = 600;
        const QUIET_ZONE: usize = 4;

        let code = QrCode::with_error_correction_level(data.as_bytes(), EcLevel::H)
            .context("Failed to generate QR code")?;
        let modules = code.to_colors();
        let qr_width = code.width();
        let total_modules = qr_width + 2 * QUIET_ZONE;
        let module_px = IMAGE_SIZE as f64 / total_modules as f64;
        let corner_radius = module_px * 0.20;

        let mut img = RgbaImage::from_pixel(IMAGE_SIZE, IMAGE_SIZE, Rgba([255, 255, 255, 255]));

        let center = IMAGE_SIZE as f64 / 2.0;
        let max_dist = center * std::f64::consts::SQRT_2;

        for my in 0..qr_width {
            for mx in 0..qr_width {
                let idx = my * qr_width + mx;
                if modules[idx] != qrcode::types::Color::Dark {
                    continue;
                }

                let mod_x = (mx + QUIET_ZONE) as f64 * module_px;
                let mod_y = (my + QUIET_ZONE) as f64 * module_px;
                let mod_cx = mod_x + module_px / 2.0;
                let mod_cy = mod_y + module_px / 2.0;
                let color = gradient_color(mod_cx, mod_cy, center, max_dist);

                let px_start_x = mod_x.floor() as u32;
                let px_start_y = mod_y.floor() as u32;
                let px_end_x = ((mod_x + module_px).ceil() as u32).min(IMAGE_SIZE);
                let px_end_y = ((mod_y + module_px).ceil() as u32).min(IMAGE_SIZE);

                for py in px_start_y..px_end_y {
                    for px in px_start_x..px_end_x {
                        let rel_x = px as f64 - mod_x;
                        let rel_y = py as f64 - mod_y;
                        if is_inside_rounded_rect(rel_x, rel_y, module_px, module_px, corner_radius) {
                            img.put_pixel(px, py, color);
                        }
                    }
                }
            }
        }

        Self::overlay_logo(&mut img, IMAGE_SIZE)?;
        Ok(img)
    }

    /// Overlay the Termopus logo at the center with a circular white background.
    fn overlay_logo(img: &mut RgbaImage, image_size: u32) -> Result<()> {
        let logo_full = image::load_from_memory(LOGO_PNG)
            .context("Failed to decode embedded logo PNG")?
            .to_rgba8();

        let logo_size = (image_size as f64 * 0.22) as u32;
        let logo_resized = image::imageops::resize(
            &logo_full,
            logo_size,
            logo_size,
            image::imageops::FilterType::Lanczos3,
        );

        // White circle background (8px padding)
        let bg_padding: u32 = 8;
        let bg_size = logo_size + bg_padding * 2;
        let bg_radius = bg_size as f64 / 2.0;
        let bg_offset = (image_size - bg_size) / 2;

        for y in 0..bg_size {
            for x in 0..bg_size {
                let dx = x as f64 - bg_radius + 0.5;
                let dy = y as f64 - bg_radius + 0.5;
                if dx * dx + dy * dy <= bg_radius * bg_radius {
                    img.put_pixel(bg_offset + x, bg_offset + y, Rgba([255, 255, 255, 255]));
                }
            }
        }

        // Circular crop the resized logo
        let mut circular_logo = RgbaImage::new(logo_size, logo_size);
        let logo_radius = logo_size as f64 / 2.0;
        for y in 0..logo_size {
            for x in 0..logo_size {
                let dx = x as f64 - logo_radius + 0.5;
                let dy = y as f64 - logo_radius + 0.5;
                if dx * dx + dy * dy <= logo_radius * logo_radius {
                    circular_logo.put_pixel(x, y, *logo_resized.get_pixel(x, y));
                }
            }
        }

        let logo_offset = ((image_size - logo_size) / 2) as i64;
        image::imageops::overlay(img, &circular_logo, logo_offset, logo_offset);
        Ok(())
    }
}

/// A generated QR code image that can be rendered to different outputs.
pub struct QrImage {
    code: QrCode,
    data: String,
}

impl QrImage {
    /// Print the QR code to the terminal using Unicode block characters.
    ///
    /// Uses dense 1x2 Unicode blocks for compact rendering. The colors
    /// are inverted (light-on-dark) for better visibility on dark terminal
    /// backgrounds.
    pub fn print_to_terminal(&self) {
        let image = self
            .code
            .render::<unicode::Dense1x2>()
            .dark_color(unicode::Dense1x2::Light)
            .light_color(unicode::Dense1x2::Dark)
            .quiet_zone(true)
            .build();

        println!("{}", image);
    }

    /// Print the QR code using simple ASCII characters.
    ///
    /// Less compact than Unicode rendering but works in terminals that
    /// don't support Unicode block characters.
    pub fn print_ascii(&self) {
        let width = self.code.width();
        let data = self.code.to_colors();

        // Top quiet zone
        println!();

        for y in 0..width {
            print!("  "); // Left quiet zone
            for x in 0..width {
                let idx = y * width + x;
                if data[idx] == qrcode::types::Color::Dark {
                    print!("##");
                } else {
                    print!("  ");
                }
            }
            println!(); // Right quiet zone + newline
        }

        println!(); // Bottom quiet zone
    }

    /// Save the QR code as a branded PNG image file.
    ///
    /// Uses the branded renderer (gradient, rounded modules, centered logo).
    pub fn save_png(&self, path: &str) -> Result<()> {
        let img = QrGenerator::generate_branded(&self.data)?;
        img.save(path)
            .context(format!("Failed to save QR code PNG to {}", path))?;
        tracing::info!("QR code saved to: {}", path);
        Ok(())
    }

    /// Get the raw data encoded in the QR code.
    pub fn data(&self) -> &str {
        &self.data
    }

    /// Get the QR code width (number of modules per side).
    pub fn width(&self) -> usize {
        self.code.width()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_generate_qr() {
        let data = r#"{"v":1,"session":"test123"}"#;
        let result = QrGenerator::generate(data);
        assert!(result.is_ok());

        let qr = result.unwrap();
        assert!(qr.width() > 0);
        assert_eq!(qr.data(), data);
    }

    #[test]
    fn test_generate_qr_with_long_data() {
        // Simulate realistic pairing data
        let data = serde_json::json!({
            "v": 1,
            "relay": "wss://relay.example.com",
            "session": "abcdef0123456789abcdef0123456789",
            "pubkey": "dGhpcyBpcyBhIHRlc3QgcHVibGljIGtleQ==",
            "exp": 1700000300
        });
        let result = QrGenerator::generate(&data.to_string());
        assert!(result.is_ok());
    }

    #[test]
    fn test_empty_data() {
        let result = QrGenerator::generate("");
        // QR codes can encode empty data
        assert!(result.is_ok());
    }

    #[test]
    fn test_generate_branded_produces_600x600_rgba() {
        let data = r#"{"v":1,"session":"test123"}"#;
        let img = QrGenerator::generate_branded(data).unwrap();
        assert_eq!(img.width(), 600);
        assert_eq!(img.height(), 600);
    }

    #[test]
    fn test_generate_branded_with_realistic_payload() {
        let data = serde_json::json!({
            "v": 1,
            "relay": "wss://relay.example.com",
            "session": "abcdef0123456789abcdef0123456789",
            "pubkey": "dGhpcyBpcyBhIHRlc3QgcHVibGljIGtleQ==",
            "exp": 1700000300,
            "name": "MacBook Pro"
        });
        let img = QrGenerator::generate_branded(&data.to_string()).unwrap();
        assert_eq!(img.width(), 600);
        assert_eq!(img.height(), 600);
        // Center pixel should be fully opaque (logo area)
        let center = img.get_pixel(300, 300);
        assert_eq!(center[3], 255);
    }

    #[test]
    fn test_is_inside_rounded_rect() {
        // Center of 10x10 rect with radius 3: inside
        assert!(super::is_inside_rounded_rect(5.0, 5.0, 10.0, 10.0, 3.0));
        // Corner pixel outside the rounding
        assert!(!super::is_inside_rounded_rect(0.1, 0.1, 10.0, 10.0, 3.0));
        // Edge of non-corner region: inside
        assert!(super::is_inside_rounded_rect(5.0, 0.5, 10.0, 10.0, 3.0));
        // Outside entirely
        assert!(!super::is_inside_rounded_rect(-1.0, 5.0, 10.0, 10.0, 3.0));
        assert!(!super::is_inside_rounded_rect(5.0, 10.5, 10.0, 10.0, 3.0));
    }

    #[test]
    fn test_gradient_colors() {
        // Center color should be deep cyan (40, 120, 220)
        let center_color = super::gradient_color(300.0, 300.0, 300.0, 300.0 * std::f64::consts::SQRT_2);
        assert_eq!(center_color[0], 40);  // R
        assert_eq!(center_color[1], 120); // G
        assert_eq!(center_color[2], 220); // B

        // Far corner should be deep purple (100, 40, 160)
        let edge_color = super::gradient_color(0.0, 0.0, 300.0, 300.0 * std::f64::consts::SQRT_2);
        assert_eq!(edge_color[0], 100); // R
        assert_eq!(edge_color[1], 40);  // G
        assert_eq!(edge_color[2], 160); // B
    }
}
