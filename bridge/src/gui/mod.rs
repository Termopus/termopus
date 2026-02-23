//! GUI module for Termopus bridge - Menu Bar App
//!
//! Creates a macOS menu bar (system tray) app that shows:
//! - Session list in left panel
//! - QR code view during pairing
//! - Real-time terminal output after connection
//! - Status updates in real-time

use eframe::egui;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tray_icon::{
    menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem},
    TrayIconBuilder,
};

/// Generate branded QR code image for GUI display.
///
/// Delegates to the centralized QR generator which produces a 600×600 RGBA image
/// with rounded modules, radial gradient, and logo overlay.
fn generate_qr_image(data: &str) -> Option<egui::ColorImage> {
    use crate::qr::generator::QrGenerator;

    let rgba_img = QrGenerator::generate_branded(data).ok()?;
    let size = [rgba_img.width() as usize, rgba_img.height() as usize];
    let pixels: Vec<egui::Color32> = rgba_img
        .pixels()
        .map(|p| egui::Color32::from_rgba_unmultiplied(p[0], p[1], p[2], p[3]))
        .collect();

    Some(egui::ColorImage { size, pixels })
}

/// Create the tray icon by loading the bundled PNG from Resources,
/// or falling back to a programmatic octopus silhouette.
fn create_tray_icon_image() -> tray_icon::Icon {
    // Try loading from bundle Resources
    if let Some(icon) = load_bundled_tray_icon() {
        return icon;
    }

    // Fallback: 22x22 cute octopus silhouette
    let size = 22u32;
    let mut rgba = Vec::with_capacity((size * size * 4) as usize);

    // Cute octopus: big round head, small curvy tentacles
    // 0 = transparent, 1 = filled (black)
    #[rustfmt::skip]
    let octopus: [[u8; 22]; 22] = [
        [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
        [0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,0,0,0,0,0,0,0],
        [0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,0,0,0,0,0,0],
        [0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,0,0,0,0,0],
        [0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0,0,0,0],
        [0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0,0,0,0],
        [0,0,0,0,1,1,1,0,0,1,1,1,1,0,0,1,1,1,0,0,0,0], // eyes
        [0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0,0,0,0],
        [0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0,0,0,0],
        [0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0,0,0,0],
        [0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,0,0,0,0,0],
        [0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,0,0,0,0,0],
        [0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,0,0,0,0,0,0],
        [0,0,0,0,0,1,1,0,1,1,0,0,1,1,0,1,1,0,0,0,0,0], // short tentacles
        [0,0,0,0,1,1,0,0,1,0,0,0,0,1,0,0,1,1,0,0,0,0],
        [0,0,0,1,1,0,0,1,1,0,0,0,0,1,1,0,0,1,1,0,0,0],
        [0,0,0,1,0,0,0,1,0,0,0,0,0,0,1,0,0,0,1,0,0,0],
        [0,0,1,1,0,0,1,1,0,0,0,0,0,0,1,1,0,0,1,1,0,0],
        [0,0,1,0,0,0,1,0,0,0,0,0,0,0,0,1,0,0,0,1,0,0],
        [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
        [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
        [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
    ];

    for y in 0..size {
        for x in 0..size {
            if octopus[y as usize][x as usize] == 1 {
                // Black for menu bar visibility
                rgba.extend_from_slice(&[30, 30, 30, 255]);
            } else {
                rgba.extend_from_slice(&[0, 0, 0, 0]);
            }
        }
    }
    tray_icon::Icon::from_rgba(rgba, size, size).expect("Failed to create icon")
}

/// Load the tray icon PNG from various locations.
fn load_bundled_tray_icon() -> Option<tray_icon::Icon> {
    let exe = std::env::current_exe().ok()?;
    let exe_dir = exe.parent()?;

    // Try multiple locations
    let mut candidates = vec![];

    // 1. App bundle Resources (when running as .app)
    if let Some(bundle_resources) = exe_dir.parent().map(|p| p.join("Resources")) {
        candidates.push(bundle_resources.join("tray_icon.png"));
        candidates.push(bundle_resources.join("tray_icon@2x.png"));
    }

    // 2. Assets folder relative to exe (development: target/release/)
    // Go up from target/release to project root, then into assets
    if let Some(project_root) = exe_dir.parent().and_then(|p| p.parent()) {
        candidates.push(project_root.join("assets/tray_icon.png"));
        candidates.push(project_root.join("assets/tray_icon@2x.png"));
        candidates.push(project_root.join("assets/tray_icon_32.png"));
    }

    // 3. Assets folder relative to bridge (development: running from bridge/)
    if let Some(project_root) = exe_dir.parent().and_then(|p| p.parent()).and_then(|p| p.parent()) {
        candidates.push(project_root.join("assets/tray_icon.png"));
        candidates.push(project_root.join("assets/tray_icon@2x.png"));
    }

    for path in &candidates {
        if path.exists() {
            if let Ok(img) = image::open(path) {
                let rgba_img = img.to_rgba8();
                let (w, h) = rgba_img.dimensions();
                let pixels = rgba_img.into_raw();
                if let Ok(icon) = tray_icon::Icon::from_rgba(pixels, w, h) {
                    tracing::info!("Loaded tray icon from: {:?}", path);
                    return Some(icon);
                }
            }
        }
    }

    None
}

/// Load an app icon for the eframe window (fixes the generic "e" icon).
/// Checks app bundle Resources first, then project assets/ for development.
fn load_window_icon() -> Option<egui::IconData> {
    let exe = std::env::current_exe().ok()?;
    let exe_dir = exe.parent()?;

    let mut candidates = vec![];

    // 1. App bundle Resources (when running as .app)
    let resources = exe_dir.parent()?.join("Resources");
    candidates.push(resources.join("icon_128x128.png"));
    candidates.push(resources.join("Termopus.icns"));

    // 2. Project assets/ (development: target/release/ → project root)
    if let Some(project_root) = exe_dir.parent().and_then(|p| p.parent()) {
        candidates.push(project_root.join("assets/icon_128x128.png"));
    }
    // 3. Bridge subdir (development: bridge/target/release/ → project root)
    if let Some(project_root) = exe_dir.parent().and_then(|p| p.parent()).and_then(|p| p.parent()) {
        candidates.push(project_root.join("assets/icon_128x128.png"));
    }

    for path in &candidates {
        if let Ok(img) = image::open(path) {
            let rgba_img = img.to_rgba8();
            let (w, h) = rgba_img.dimensions();
            let pixels = rgba_img.into_raw();
            tracing::info!("Loaded window icon from: {:?}", path);
            return Some(egui::IconData {
                rgba: pixels,
                width: w,
                height: h,
            });
        }
    }

    None
}

// =====================================================================
// Multi-session GUI
// =====================================================================

use crate::session::manager::{
    ActiveSession, SessionCommand, SessionHandles, SessionStatus, SharedBridgeManager,
};

/// Multi-session GUI application
pub struct TermopusMultiApp {
    manager: SharedBridgeManager,
    handles: SessionHandles,
    new_session_tx: std::sync::mpsc::Sender<()>,
    #[allow(dead_code)]
    relay_url: String,
    qr_texture: Option<egui::TextureHandle>,
    qr_texture_session_id: Option<String>,
    scroll_to_bottom: bool,
    show_window_requested: Arc<AtomicBool>,
    #[allow(dead_code)]
    tray_icon: Option<tray_icon::TrayIcon>,
    show_quit_dialog: bool,
    shutting_down: bool,
    input_text: String,
    pin_setup_confirm: String,
    touch_id_checking: bool,
    auto_touch_id_triggered: bool,
    /// Recovery code to display after PIN setup (shown once, then cleared)
    recovery_code_display: Option<String>,
    /// Whether the "Forgot PIN?" recovery input is shown
    show_forgot_pin: bool,
    /// Recovery code input field
    recovery_input: String,
}

impl TermopusMultiApp {
    pub fn new(
        manager: SharedBridgeManager,
        handles: SessionHandles,
        new_session_tx: std::sync::mpsc::Sender<()>,
        relay_url: String,
        show_window_requested: Arc<AtomicBool>,
        tray_icon: Option<tray_icon::TrayIcon>,
    ) -> Self {
        Self {
            manager,
            handles,
            new_session_tx,
            relay_url,
            qr_texture: None,
            qr_texture_session_id: None,
            scroll_to_bottom: true,
            show_window_requested,
            tray_icon,
            show_quit_dialog: false,
            shutting_down: false,
            input_text: String::new(),
            pin_setup_confirm: String::new(),
            touch_id_checking: false,
            auto_touch_id_triggered: false,
            recovery_code_display: None,
            show_forgot_pin: false,
            recovery_input: String::new(),
        }
    }

    fn send_session_command(&self, session_id: &str, cmd: SessionCommand) {
        let handles = self.handles.blocking_lock();
        if let Some(handle) = handles.get(session_id) {
            let _ = handle.cmd_tx.blocking_send(cmd);
        }
    }

    fn render_session_list(&mut self, ui: &mut egui::Ui) {
        ui.add_space(8.0);
        ui.label(egui::RichText::new("Sessions").size(14.0).strong());
        ui.add_space(4.0);
        ui.separator();
        ui.add_space(4.0);

        let mgr = self.manager.blocking_read();
        let sessions: Vec<ActiveSession> = mgr.all_sessions().into_iter().cloned().collect();
        let active_id = mgr.active_session_id().map(|s| s.to_string());
        drop(mgr);

        for session in &sessions {
            let is_active = active_id.as_deref() == Some(&session.id);
            let status_icon = match session.status {
                SessionStatus::Connected => "🟢",
                SessionStatus::WaitingForPairing | SessionStatus::Initializing => "🟡",
                SessionStatus::Error(_) => "🔴",
                SessionStatus::Disconnected => "⚪",
                SessionStatus::Connecting => "🔵",
            };

            let label = format!("{} {}", status_icon, session.name);
            let response = ui.selectable_label(is_active, &label);

            if response.clicked() && !is_active {
                let mut mgr = self.manager.blocking_write();
                mgr.set_active_session(&session.id);
                // Reset QR texture when switching sessions
                self.qr_texture = None;
                self.qr_texture_session_id = None;
            }

            // Right-click context menu
            response.context_menu(|ui| {
                if ui.button("Terminate").clicked() {
                    self.send_session_command(&session.id, SessionCommand::Terminate);
                    ui.close_menu();
                }
                if ui.button("🗑 Delete").clicked() {
                    // Terminate first, then clean up storage and remove
                    self.send_session_command(&session.id, SessionCommand::Terminate);
                    crate::config::storage::clear_claude_session_id(&session.id);
                    let _ = crate::config::storage::remove_session(&session.id);
                    self.manager.blocking_write().remove_session(&session.id);
                    // Remove task handle
                    self.handles.blocking_lock().remove(&session.id);
                    // Reset QR texture if we deleted the active session
                    if is_active {
                        self.qr_texture = None;
                        self.qr_texture_session_id = None;
                    }
                    ui.close_menu();
                }
            });
        }

        ui.add_space(8.0);
        ui.separator();
        ui.add_space(4.0);

        if ui
            .button(egui::RichText::new("+ New Session").size(12.0))
            .clicked()
        {
            let _ = self.new_session_tx.send(());
            // Reset QR texture so the new session's QR is generated
            self.qr_texture = None;
            self.qr_texture_session_id = None;
        }

        // Quit button at the bottom
        ui.with_layout(egui::Layout::bottom_up(egui::Align::Center), |ui| {
            ui.add_space(8.0);
            let quit_btn = egui::Button::new(
                egui::RichText::new("Quit Termopus")
                    .size(11.0)
                    .color(egui::Color32::from_rgb(180, 80, 80)),
            );
            if ui.add(quit_btn).clicked() {
                self.show_quit_dialog = true;
            }
        });
    }

    fn render_active_session(&mut self, ui: &mut egui::Ui, ctx: &egui::Context) {
        let mgr = self.manager.blocking_read();
        let active = mgr.active_session().cloned();
        drop(mgr);

        match active {
            Some(session) => match session.status {
                SessionStatus::Initializing | SessionStatus::WaitingForPairing => {
                    self.render_pairing_for(&session, ui, ctx);
                }
                SessionStatus::Connected | SessionStatus::Connecting => {
                    self.render_terminal_for(&session, ui);
                }
                SessionStatus::Error(ref msg) => {
                    self.render_error_for(&session.name, msg, ui);
                }
                SessionStatus::Disconnected => {
                    self.render_disconnected_for(&session.name, ui);
                }
            },
            None => {
                ui.vertical_centered(|ui| {
                    ui.add_space(80.0);
                    ui.label(
                        egui::RichText::new("No sessions. Click '+ New Session' to start.")
                            .size(14.0)
                            .weak(),
                    );
                });
            }
        }
    }

    fn render_pairing_for(
        &mut self,
        session: &ActiveSession,
        ui: &mut egui::Ui,
        ctx: &egui::Context,
    ) {
        ui.vertical_centered(|ui| {
            ui.add_space(15.0);
            ui.heading(egui::RichText::new("🐙 Termopus").size(24.0).strong());
            ui.add_space(3.0);
            ui.label(
                egui::RichText::new(format!("{}", session.name))
                    .size(12.0)
                    .weak(),
            );
            ui.add_space(20.0);

            if session.qr_locked {
                // QR LOCKED: Show identity gate
                self.render_identity_gate(session, ui, ctx);
            } else {
                // QR UNLOCKED: Show QR code
                ui.label(
                    egui::RichText::new("Scan to connect")
                        .size(12.0)
                        .weak(),
                );
                ui.add_space(10.0);

                // QR code
                if let Some(ref qr_data) = session.qr_data {
                    let needs_update = self
                        .qr_texture_session_id
                        .as_ref()
                        .map_or(true, |id| id != &session.id);
                    if needs_update || self.qr_texture.is_none() {
                        if let Some(image) = generate_qr_image(qr_data) {
                            self.qr_texture = Some(ctx.load_texture(
                                "qr_code",
                                image,
                                egui::TextureOptions::NEAREST,
                            ));
                            self.qr_texture_session_id = Some(session.id.clone());
                        }
                    }
                }

                if let Some(ref texture) = self.qr_texture {
                    let size = egui::vec2(300.0, 300.0);
                    ui.add(egui::Image::new(texture).fit_to_exact_size(size));
                } else {
                    ui.spinner();
                    ui.label("Generating QR code...");
                }

                ui.add_space(15.0);

                // Status
                let (text, color, icon) = match session.status {
                    SessionStatus::WaitingForPairing => {
                        ("Waiting for phone scan...", egui::Color32::from_rgb(150, 150, 150), "⏳")
                    }
                    _ => {
                        ("Initializing...", egui::Color32::from_rgb(150, 150, 150), "⏳")
                    }
                };
                ui.horizontal(|ui| {
                    ui.label(egui::RichText::new(icon).size(14.0));
                    ui.label(egui::RichText::new(text).size(13.0).color(color));
                });

                ui.add_space(15.0);
                ui.separator();
                ui.add_space(10.0);

                ui.label(egui::RichText::new("1. Open Termopus on your phone").size(11.0).weak());
                ui.label(egui::RichText::new("2. Tap 'Scan QR Code'").size(11.0).weak());
                ui.label(egui::RichText::new("3. Point camera at this code").size(11.0).weak());
            }
        });
    }

    fn render_identity_gate(
        &mut self,
        session: &ActiveSession,
        ui: &mut egui::Ui,
        ctx: &egui::Context,
    ) {
        let session_id = session.id.clone();

        // ── Recovery code display (shown once after PIN setup) ──
        if let Some(ref code) = self.recovery_code_display {
            ui.label(egui::RichText::new("🔑").size(48.0));
            ui.add_space(12.0);
            ui.label(
                egui::RichText::new("Your Recovery Code")
                    .size(16.0)
                    .strong(),
            );
            ui.add_space(4.0);
            ui.label(
                egui::RichText::new("Save this code somewhere safe.\nYou'll need it if you forget your PIN.")
                    .size(12.0)
                    .weak(),
            );
            ui.add_space(16.0);

            // Large recovery code display
            ui.add(
                egui::Label::new(
                    egui::RichText::new(code)
                        .size(28.0)
                        .strong()
                        .monospace()
                        .color(egui::Color32::from_rgb(100, 200, 100)),
                )
            );
            ui.add_space(16.0);

            ui.label(
                egui::RichText::new("This code will NOT be shown again.")
                    .size(11.0)
                    .color(egui::Color32::from_rgb(255, 180, 100)),
            );
            ui.add_space(16.0);

            let done_btn = egui::Button::new(
                egui::RichText::new("I've Saved It — Continue").size(14.0),
            )
            .min_size(egui::vec2(220.0, 36.0));

            if ui.add(done_btn).clicked() {
                self.recovery_code_display = None;
                // Now unlock the QR
                let mut mgr = self.manager.blocking_write();
                mgr.set_qr_locked(&session_id, false);
                if let Some(s) = mgr.get_session_mut(&session_id) {
                    s.pin_input.clear();
                    s.pin_error = None;
                }
            }
            return;
        }

        // Lock icon
        ui.label(egui::RichText::new("🔒").size(48.0));
        ui.add_space(12.0);

        // ── Forgot PIN? Recovery flow ──
        if self.show_forgot_pin {
            ui.label(
                egui::RichText::new("Reset PIN")
                    .size(16.0)
                    .strong(),
            );
            ui.add_space(4.0);
            ui.label(
                egui::RichText::new("Enter the recovery code you saved during PIN setup")
                    .size(12.0)
                    .weak(),
            );
            ui.add_space(16.0);

            let recovery_response = ui.add(
                egui::TextEdit::singleline(&mut self.recovery_input)
                    .hint_text("8-character code")
                    .desired_width(200.0)
                    .font(egui::TextStyle::Monospace),
            );
            // Uppercase and strip spaces as user types
            if recovery_response.changed() {
                self.recovery_input = self.recovery_input.to_uppercase()
                    .chars().filter(|c| !c.is_whitespace()).collect();
            }

            ui.add_space(8.0);

            // Error message
            if let Some(ref err) = session.pin_error {
                ui.label(
                    egui::RichText::new(err)
                        .size(12.0)
                        .color(egui::Color32::from_rgb(255, 100, 100)),
                );
                ui.add_space(8.0);
            }

            let enter_pressed = recovery_response.lost_focus()
                && ui.input(|i| i.key_pressed(egui::Key::Enter));

            let verify_btn = egui::Button::new(
                egui::RichText::new("Verify & Reset PIN").size(14.0),
            )
            .min_size(egui::vec2(200.0, 36.0));

            if ui.add_enabled(self.recovery_input.len() == 8, verify_btn).clicked()
                || (enter_pressed && self.recovery_input.len() == 8)
            {
                match crate::pin::verify_recovery_code(&self.recovery_input) {
                    Ok(true) => {
                        // Recovery success — clear PIN + recovery, go to PIN setup
                        crate::pin::clear_pin().ok();
                        crate::pin::clear_recovery().ok();
                        self.show_forgot_pin = false;
                        self.recovery_input.clear();
                        if let Some(s) = self.manager.blocking_write().get_session_mut(&session_id) {
                            s.pin_error = None;
                            s.pin_input.clear();
                        }
                    }
                    Ok(false) => {
                        if let Some(s) = self.manager.blocking_write().get_session_mut(&session_id) {
                            s.pin_error = Some("Wrong recovery code".to_string());
                        }
                        self.recovery_input.clear();
                    }
                    Err(e) => {
                        if let Some(s) = self.manager.blocking_write().get_session_mut(&session_id) {
                            s.pin_error = Some(format!("Error: {}", e));
                        }
                    }
                }
            }

            ui.add_space(12.0);
            if ui.link("Back to PIN entry").clicked() {
                self.show_forgot_pin = false;
                self.recovery_input.clear();
                if let Some(s) = self.manager.blocking_write().get_session_mut(&session_id) {
                    s.pin_error = None;
                }
            }
            return;
        }

        if !crate::pin::has_pin() {
            // ── FIRST TIME: Set PIN ──
            ui.label(
                egui::RichText::new("Set Your Termopus PIN")
                    .size(16.0)
                    .strong(),
            );
            ui.add_space(4.0);
            ui.label(
                egui::RichText::new("Protect your QR code with a 4-8 digit PIN")
                    .size(12.0)
                    .weak(),
            );
            ui.add_space(16.0);

            // PIN input
            ui.label(egui::RichText::new("PIN:").size(12.0));
            let mut pin_input = {
                let mgr = self.manager.blocking_read();
                mgr.get_session(&session_id)
                    .map(|s| s.pin_input.clone())
                    .unwrap_or_default()
            };
            let pin_response = ui.add(
                egui::TextEdit::singleline(&mut pin_input)
                    .password(true)
                    .hint_text("4-8 digits")
                    .desired_width(200.0)
                    .font(egui::TextStyle::Monospace),
            );
            if pin_response.changed() {
                pin_input.retain(|c| c.is_ascii_digit());
                if pin_input.len() > 8 {
                    pin_input.truncate(8);
                }
                if let Some(s) = self
                    .manager
                    .blocking_write()
                    .get_session_mut(&session_id)
                {
                    s.pin_input = pin_input.clone();
                }
            }

            ui.add_space(8.0);

            // Confirm input
            ui.label(egui::RichText::new("Confirm PIN:").size(12.0));
            let confirm_response = ui.add(
                egui::TextEdit::singleline(&mut self.pin_setup_confirm)
                    .password(true)
                    .hint_text("Re-enter PIN")
                    .desired_width(200.0)
                    .font(egui::TextStyle::Monospace),
            );
            if confirm_response.changed() {
                self.pin_setup_confirm.retain(|c| c.is_ascii_digit());
                if self.pin_setup_confirm.len() > 8 {
                    self.pin_setup_confirm.truncate(8);
                }
            }

            ui.add_space(12.0);

            // Error message
            if let Some(ref err) = session.pin_error {
                ui.label(
                    egui::RichText::new(err)
                        .size(12.0)
                        .color(egui::Color32::from_rgb(255, 100, 100)),
                );
                ui.add_space(8.0);
            }

            // Set PIN button
            let can_set =
                pin_input.len() >= 4 && pin_input.len() <= 8 && self.pin_setup_confirm.len() >= 4;
            let set_btn = egui::Button::new(
                egui::RichText::new("Set PIN & Show QR").size(14.0),
            )
            .min_size(egui::vec2(200.0, 36.0));

            if ui.add_enabled(can_set, set_btn).clicked() {
                if pin_input != self.pin_setup_confirm {
                    if let Some(s) = self
                        .manager
                        .blocking_write()
                        .get_session_mut(&session_id)
                    {
                        s.pin_error = Some("PINs don't match".to_string());
                    }
                } else {
                    match crate::pin::set_pin(&pin_input) {
                        Ok(()) => {
                            // Generate and store recovery code
                            let code = crate::pin::generate_recovery_code();
                            if let Err(e) = crate::pin::set_recovery_code(&code) {
                                tracing::error!("Failed to store recovery code: {}", e);
                            }
                            // Show recovery code (QR unlock deferred until user acknowledges)
                            self.recovery_code_display = Some(code);
                            self.pin_setup_confirm.clear();
                        }
                        Err(e) => {
                            if let Some(s) = self
                                .manager
                                .blocking_write()
                                .get_session_mut(&session_id)
                            {
                                s.pin_error =
                                    Some(format!("Failed to set PIN: {}", e));
                            }
                        }
                    }
                }
            }
        } else {
            // ── RETURNING USER: Enter PIN ──
            ui.label(
                egui::RichText::new("Enter PIN to Show QR")
                    .size(16.0)
                    .strong(),
            );
            ui.add_space(4.0);
            ui.label(
                egui::RichText::new("Verify your identity to display the QR code")
                    .size(12.0)
                    .weak(),
            );
            ui.add_space(16.0);

            // Touch ID (Mac only) — auto-trigger on first render, manual retry button after
            #[cfg(target_os = "macos")]
            {
                let touch_id_available = crate::touch_id::is_available();

                // Auto-trigger Touch ID on first render of gate
                if touch_id_available && !self.touch_id_checking && !self.auto_touch_id_triggered {
                    self.auto_touch_id_triggered = true;
                    self.touch_id_checking = true;
                    let mgr = self.manager.clone();
                    let sid = session_id.clone();
                    let ctx_clone = ctx.clone();
                    std::thread::spawn(move || {
                        let rt = tokio::runtime::Runtime::new().unwrap();
                        let result = rt.block_on(crate::touch_id::prompt_touch_id(
                            "Show Termopus QR code",
                        ));
                        match result {
                            Ok(true) => {
                                mgr.blocking_write().set_qr_locked(&sid, false);
                            }
                            _ => {
                                if let Some(s) =
                                    mgr.blocking_write().get_session_mut(&sid)
                                {
                                    s.pin_error = Some(
                                        "Touch ID failed — use PIN instead"
                                            .to_string(),
                                    );
                                }
                            }
                        }
                        ctx_clone.request_repaint();
                    });
                }

                // Manual retry button (shown after auto-trigger failed)
                if touch_id_available && !self.touch_id_checking {
                    let tid_btn = egui::Button::new(
                        egui::RichText::new("🔐 Retry Touch ID").size(14.0),
                    )
                    .min_size(egui::vec2(200.0, 36.0));

                    if ui.add(tid_btn).clicked() {
                        self.touch_id_checking = true;
                        let mgr = self.manager.clone();
                        let sid = session_id.clone();
                        let ctx_clone = ctx.clone();
                        if let Some(s) = mgr.blocking_write().get_session_mut(&sid) {
                            s.pin_error = None;
                        }
                        std::thread::spawn(move || {
                            let rt = tokio::runtime::Runtime::new().unwrap();
                            let result = rt.block_on(crate::touch_id::prompt_touch_id(
                                "Show Termopus QR code",
                            ));
                            match result {
                                Ok(true) => {
                                    mgr.blocking_write().set_qr_locked(&sid, false);
                                }
                                _ => {
                                    if let Some(s) =
                                        mgr.blocking_write().get_session_mut(&sid)
                                    {
                                        s.pin_error = Some(
                                            "Touch ID failed — use PIN instead"
                                                .to_string(),
                                        );
                                    }
                                }
                            }
                            ctx_clone.request_repaint();
                        });
                    }
                    ui.add_space(12.0);
                    ui.label(egui::RichText::new("— or —").size(11.0).weak());
                    ui.add_space(12.0);
                }

                if self.touch_id_checking {
                    let (still_locked, has_error) = {
                        let mgr = self.manager.blocking_read();
                        let session = mgr.get_session(&session_id);
                        (
                            session.map(|s| s.qr_locked).unwrap_or(true),
                            session.map(|s| s.pin_error.is_some()).unwrap_or(false),
                        )
                    };
                    if !still_locked || has_error {
                        self.touch_id_checking = false;
                    } else {
                        ui.spinner();
                        ui.label(
                            egui::RichText::new("Authenticating with Touch ID...").size(12.0),
                        );
                        return;
                    }
                    ui.add_space(12.0);
                }
            }

            // PIN input
            let mut pin_input = {
                let mgr = self.manager.blocking_read();
                mgr.get_session(&session_id)
                    .map(|s| s.pin_input.clone())
                    .unwrap_or_default()
            };
            let pin_response = ui.add(
                egui::TextEdit::singleline(&mut pin_input)
                    .password(true)
                    .hint_text("Enter PIN")
                    .desired_width(200.0)
                    .font(egui::TextStyle::Monospace),
            );
            if pin_response.changed() {
                pin_input.retain(|c| c.is_ascii_digit());
                if pin_input.len() > 8 {
                    pin_input.truncate(8);
                }
                if let Some(s) = self
                    .manager
                    .blocking_write()
                    .get_session_mut(&session_id)
                {
                    s.pin_input = pin_input.clone();
                }
            }

            ui.add_space(8.0);

            // Error message
            if let Some(ref err) = session.pin_error {
                ui.label(
                    egui::RichText::new(err)
                        .size(12.0)
                        .color(egui::Color32::from_rgb(255, 100, 100)),
                );
                ui.add_space(8.0);
            }

            // Unlock button
            let unlock_btn = egui::Button::new(
                egui::RichText::new("Unlock").size(14.0),
            )
            .min_size(egui::vec2(200.0, 36.0));

            let enter_pressed = pin_response.lost_focus()
                && ui.input(|i| i.key_pressed(egui::Key::Enter));

            if ui
                .add_enabled(pin_input.len() >= 4, unlock_btn)
                .clicked()
                || (enter_pressed && pin_input.len() >= 4)
            {
                match crate::pin::verify_pin(&pin_input) {
                    Ok(true) => {
                        let mut mgr = self.manager.blocking_write();
                        mgr.set_qr_locked(&session_id, false);
                        if let Some(s) = mgr.get_session_mut(&session_id) {
                            s.pin_input.clear();
                            s.pin_error = None;
                        }
                    }
                    Ok(false) => {
                        if let Some(s) = self
                            .manager
                            .blocking_write()
                            .get_session_mut(&session_id)
                        {
                            s.pin_error = Some("Wrong PIN".to_string());
                            s.pin_input.clear();
                        }
                    }
                    Err(e) => {
                        if let Some(s) = self
                            .manager
                            .blocking_write()
                            .get_session_mut(&session_id)
                        {
                            s.pin_error = Some(format!("Error: {}", e));
                        }
                    }
                }
            }

            // Forgot PIN link
            ui.add_space(16.0);
            if crate::pin::has_recovery_code() {
                if ui.link("Forgot PIN?").clicked() {
                    self.show_forgot_pin = true;
                    self.recovery_input.clear();
                    if let Some(s) = self.manager.blocking_write().get_session_mut(&session_id) {
                        s.pin_error = None;
                    }
                }
            }
        }
    }

    fn render_terminal_for(&mut self, session: &ActiveSession, ui: &mut egui::Ui) {
        // Header
        ui.horizontal(|ui| {
            ui.label(egui::RichText::new("🐙 Termopus").size(16.0).strong());
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                let badge_frame = egui::Frame::none()
                    .fill(egui::Color32::from_rgb(100, 200, 100).gamma_multiply(0.2))
                    .inner_margin(egui::Margin::symmetric(8.0, 2.0))
                    .rounding(egui::Rounding::same(10.0));
                badge_frame.show(ui, |ui| {
                    ui.label(
                        egui::RichText::new("Connected")
                            .size(10.0)
                            .color(egui::Color32::from_rgb(100, 200, 100)),
                    );
                });
            });
        });

        ui.add_space(5.0);
        ui.separator();
        ui.add_space(5.0);

        // Session info and controls
        ui.horizontal(|ui| {
            ui.label(egui::RichText::new(&session.name).size(11.0).strong());

            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                let terminate_btn = egui::Button::new(
                    egui::RichText::new("⏹ Terminate")
                        .size(11.0)
                        .color(egui::Color32::from_rgb(255, 100, 100)),
                );
                if ui.add(terminate_btn).clicked() {
                    self.send_session_command(&session.id, SessionCommand::Terminate);
                }

                // Open the session's file folder in Finder
                let folder_btn = egui::Button::new(
                    egui::RichText::new("📂 Open Folder")
                        .size(11.0)
                        .color(egui::Color32::from_rgb(100, 180, 255)),
                );
                if ui.add(folder_btn).clicked() {
                    if let Some(dir) = crate::file_transfer::protocol::session_dir(&session.id) {
                        let _ = std::fs::create_dir_all(&dir);
                        #[cfg(target_os = "macos")]
                        let _ = std::process::Command::new("open").arg(&dir).spawn();
                        #[cfg(target_os = "linux")]
                        let _ = std::process::Command::new("xdg-open").arg(&dir).spawn();
                    }
                }
            });
        });

        ui.add_space(5.0);

        // Terminal output
        let terminal_frame = egui::Frame::none()
            .fill(egui::Color32::from_rgb(30, 30, 30))
            .inner_margin(egui::Margin::same(8.0))
            .rounding(egui::Rounding::same(4.0));

        terminal_frame.show(ui, |ui| {
            let scroll_area = egui::ScrollArea::vertical()
                .auto_shrink([false, false])
                .stick_to_bottom(self.scroll_to_bottom);

            scroll_area.show(ui, |ui| {
                ui.set_min_height(350.0);

                if session.terminal_output.is_empty() {
                    ui.vertical_centered(|ui| {
                        ui.add_space(80.0);
                        ui.spinner();
                        ui.add_space(10.0);
                        ui.label(
                            egui::RichText::new("Starting Claude Code...")
                                .size(12.0)
                                .weak(),
                        );
                    });
                } else {
                    let text = egui::RichText::new(&session.terminal_output)
                        .size(11.0)
                        .monospace()
                        .color(egui::Color32::from_rgb(200, 200, 200));
                    ui.label(text);
                }
            });
        });

        ui.add_space(10.0);

        // Input bar (setup phase only)
        if !session.claude_authenticated {
            let input_frame = egui::Frame::none()
                .fill(egui::Color32::from_rgb(40, 40, 50))
                .inner_margin(egui::Margin::same(8.0))
                .rounding(egui::Rounding::same(8.0));

            let session_id = session.id.clone();

            input_frame.show(ui, |ui| {
                ui.horizontal(|ui| {
                    ui.label(egui::RichText::new("Setup Mode").size(11.0).color(egui::Color32::from_rgb(150, 200, 255)));
                });

                ui.add_space(8.0);

                // Quick buttons
                ui.horizontal(|ui| {
                    let quick_buttons = [
                        ("1", "1"),
                        ("2", "2"),
                        ("y", "y"),
                        ("n", "n"),
                        ("Enter", "Enter"),
                        ("Esc", "Escape"),
                    ];
                    for (label, key) in quick_buttons {
                        let btn = egui::Button::new(
                            egui::RichText::new(label).size(12.0).monospace(),
                        )
                        .min_size(egui::vec2(40.0, 28.0));
                        if ui.add(btn).clicked() {
                            self.send_session_command(
                                &session_id,
                                SessionCommand::SendInput(key.to_string()),
                            );
                        }
                    }
                });

                ui.add_space(8.0);

                // Text input
                ui.horizontal(|ui| {
                    let text_edit = egui::TextEdit::singleline(&mut self.input_text)
                        .hint_text("Type here and press Enter...")
                        .desired_width(ui.available_width() - 70.0)
                        .font(egui::TextStyle::Monospace);

                    let response = ui.add(text_edit);

                    let send_btn = egui::Button::new(egui::RichText::new("Send").size(12.0))
                        .min_size(egui::vec2(60.0, 28.0));

                    let send_clicked = ui.add(send_btn).clicked();
                    let enter_pressed = response.lost_focus()
                        && ui.input(|i| i.key_pressed(egui::Key::Enter));

                    if (send_clicked || enter_pressed) && !self.input_text.is_empty() {
                        self.send_session_command(
                            &session_id,
                            SessionCommand::SendInput(format!("{}\n", self.input_text)),
                        );
                        self.input_text.clear();
                    }
                });
            });

            ui.add_space(5.0);
            ui.label(
                egui::RichText::new(
                    "Complete Claude setup above. After login, control switches to your phone.",
                )
                .size(10.0)
                .weak(),
            );
        } else {
            ui.horizontal(|ui| {
                ui.label(
                    egui::RichText::new("✅ Claude ready - Use your phone to interact")
                        .size(10.0)
                        .weak(),
                );
            });
        }
    }

    fn render_error_for(&self, name: &str, msg: &str, ui: &mut egui::Ui) {
        ui.vertical_centered(|ui| {
            ui.add_space(80.0);
            ui.label(egui::RichText::new("❌").size(40.0));
            ui.add_space(10.0);
            ui.label(egui::RichText::new(name).size(16.0).strong());
            ui.add_space(5.0);
            ui.label(
                egui::RichText::new(msg)
                    .size(12.0)
                    .color(egui::Color32::from_rgb(255, 100, 100)),
            );
        });
    }

    fn render_disconnected_for(&self, name: &str, ui: &mut egui::Ui) {
        ui.vertical_centered(|ui| {
            ui.add_space(80.0);
            ui.label(egui::RichText::new("⚪").size(40.0));
            ui.add_space(10.0);
            ui.label(egui::RichText::new(name).size(16.0).strong());
            ui.add_space(5.0);
            ui.label(egui::RichText::new("Session disconnected").size(12.0).weak());
        });
    }

    fn render_quit_dialog_multi(&mut self, ctx: &egui::Context) {
        egui::Window::new("Quit Termopus?")
            .collapsible(false)
            .resizable(false)
            .anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0])
            .show(ctx, |ui| {
                ui.add_space(10.0);
                ui.vertical_centered(|ui| {
                    ui.label(egui::RichText::new("⚠️").size(32.0));
                    ui.add_space(10.0);
                    ui.label(egui::RichText::new("This will end all active sessions.").size(14.0));
                });

                ui.add_space(20.0);

                ui.horizontal(|ui| {
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        let quit_btn = egui::Button::new(
                            egui::RichText::new("Quit").color(egui::Color32::WHITE),
                        )
                        .fill(egui::Color32::from_rgb(220, 60, 60));

                        if ui.add(quit_btn).clicked() {
                            // Send shutdown to all sessions
                            let handles = self.handles.blocking_lock();
                            for (_, handle) in handles.iter() {
                                let _ =
                                    handle.cmd_tx.blocking_send(SessionCommand::Shutdown);
                            }
                            drop(handles);
                            self.shutting_down = true;
                            ui.ctx().send_viewport_cmd(egui::ViewportCommand::Close);
                        }

                        ui.add_space(10.0);

                        if ui.button("Cancel").clicked() {
                            self.show_quit_dialog = false;
                        }
                    });
                });

                ui.add_space(5.0);
            });
    }

    fn cleanup_dead_sessions(&self) {
        let mut handles = self.handles.blocking_lock();
        let dead_ids: Vec<String> = handles
            .iter()
            .filter(|(_, h)| h.join_handle.is_finished())
            .map(|(id, _)| id.clone())
            .collect();

        for id in dead_ids {
            handles.remove(&id);
        }
    }
}

impl eframe::App for TermopusMultiApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        // Close button (X) → minimize to tray instead of quitting
        if ctx.input(|i| i.viewport().close_requested()) {
            ctx.send_viewport_cmd(egui::ViewportCommand::CancelClose);
            if self.shutting_down {
                // Actually close — we already sent shutdown commands
                std::process::exit(0);
            } else {
                // Hide to tray
                ctx.send_viewport_cmd(egui::ViewportCommand::Visible(false));
            }
        }

        if self.show_window_requested.swap(false, Ordering::SeqCst) {
            ctx.send_viewport_cmd(egui::ViewportCommand::Visible(true));
            ctx.send_viewport_cmd(egui::ViewportCommand::Focus);
        }

        ctx.set_visuals(egui::Visuals::dark());

        // Left panel: session list
        egui::SidePanel::left("session_list")
            .min_width(160.0)
            .max_width(200.0)
            .show(ctx, |ui| {
                self.render_session_list(ui);
            });

        // Main panel: active session
        egui::CentralPanel::default().show(ctx, |ui| {
            self.render_active_session(ui, ctx);
        });

        if self.show_quit_dialog {
            self.render_quit_dialog_multi(ctx);
        }

        // Cleanup finished session tasks
        self.cleanup_dead_sessions();

        ctx.request_repaint_after(std::time::Duration::from_secs(1));
    }
}

/// Run the multi-session GUI application
pub fn run_gui_multi(
    manager: SharedBridgeManager,
    handles: SessionHandles,
    new_session_tx: std::sync::mpsc::Sender<()>,
    relay_url: String,
) -> Result<(), eframe::Error> {
    let show_window_requested = Arc::new(AtomicBool::new(false));

    // Set up tray icon
    let tray_icon = setup_tray_icon_multi(
        Arc::clone(&manager),
        Arc::clone(&handles),
        Arc::clone(&show_window_requested),
    );

    let mut viewport = egui::ViewportBuilder::default()
        .with_inner_size([900.0, 600.0])
        .with_min_inner_size([700.0, 450.0])
        .with_resizable(true)
        .with_decorations(true)
        .with_title("Termopus")
        .with_close_button(true)
        .with_active(true)
        .with_visible(true);

    if let Some(icon_data) = load_window_icon() {
        viewport = viewport.with_icon(Arc::new(icon_data));
    }

    let options = eframe::NativeOptions {
        viewport,
        centered: true,
        ..Default::default()
    };

    eframe::run_native(
        "Termopus",
        options,
        Box::new(move |_cc| {
            Ok(Box::new(TermopusMultiApp::new(
                manager,
                handles,
                new_session_tx,
                relay_url,
                show_window_requested,
                tray_icon,
            )))
        }),
    )
}

/// Set up the system tray icon for multi-session mode.
fn setup_tray_icon_multi(
    manager: SharedBridgeManager,
    handles: SessionHandles,
    show_window_requested: Arc<AtomicBool>,
) -> Option<tray_icon::TrayIcon> {
    let icon = create_tray_icon_image();

    let menu = Menu::new();

    let status_text = {
        let mgr = manager.blocking_read();
        let connected_count = mgr
            .all_sessions()
            .iter()
            .filter(|s| s.status == SessionStatus::Connected)
            .count();
        if connected_count > 0 {
            format!("● {} session(s) connected", connected_count)
        } else {
            "○ No active sessions".to_string()
        }
    };

    let status_item = MenuItem::new(&status_text, false, None);
    let _ = menu.append(&status_item);
    let _ = menu.append(&PredefinedMenuItem::separator());

    let open_item = MenuItem::new("Open Termopus", true, None);
    let _ = menu.append(&open_item);
    let _ = menu.append(&PredefinedMenuItem::separator());

    let quit_item = MenuItem::new("Quit Termopus", true, None);
    let _ = menu.append(&quit_item);

    let open_id = open_item.id().clone();
    let quit_id = quit_item.id().clone();

    match TrayIconBuilder::new()
        .with_menu(Box::new(menu))
        .with_tooltip("Termopus - Claude Code Remote")
        .with_icon(icon)
        .build()
    {
        Ok(tray) => {
            std::thread::spawn(move || {
                use std::time::Duration;
                let receiver = MenuEvent::receiver();
                loop {
                    match receiver.recv_timeout(Duration::from_millis(500)) {
                        Ok(event) => {
                            if event.id == open_id {
                                show_window_requested.store(true, Ordering::SeqCst);
                            } else if event.id == quit_id {
                                // Send shutdown to all sessions and wait for cleanup
                                let h = handles.blocking_lock();
                                for (_, handle) in h.iter() {
                                    let _ = handle
                                        .cmd_tx
                                        .blocking_send(SessionCommand::Shutdown);
                                }
                                drop(h);

                                // Wait for sessions to finish cleanup (stop Claude, relay close)
                                let deadline = std::time::Instant::now() + Duration::from_secs(3);
                                loop {
                                    let all_done = {
                                        let h = handles.blocking_lock();
                                        h.iter().all(|(_, handle)| handle.join_handle.is_finished())
                                    };
                                    if all_done || std::time::Instant::now() >= deadline {
                                        break;
                                    }
                                    std::thread::sleep(Duration::from_millis(50));
                                }

                                // Remove hooks at app level (rules are per-session via --append-system-prompt)
                                crate::hooks::config::remove_hooks().ok();
                                std::process::exit(0);
                            }
                        }
                        Err(crossbeam_channel::RecvTimeoutError::Timeout) => {}
                        Err(crossbeam_channel::RecvTimeoutError::Disconnected) => {
                            break;
                        }
                    }
                }
            });
            Some(tray)
        }
        Err(e) => {
            tracing::warn!("Failed to create tray icon: {}", e);
            None
        }
    }
}
