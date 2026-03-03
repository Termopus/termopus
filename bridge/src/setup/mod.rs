use anyhow::Result;
use tokio::sync::OnceCell;

// ============================================================================
// Pre-flight Check System
// ============================================================================

/// Result of pre-flight dependency and permission check
#[derive(Debug, Clone)]
pub struct PreflightResult {
    pub claude_ok: bool,
    pub permissions_ok: bool,
    pub claude_version: Option<String>,
    pub claude_path: Option<String>,
    pub permission_error: Option<String>,
}

impl PreflightResult {
    /// Check if everything is ready to run
    pub fn is_ready(&self) -> bool {
        self.claude_ok && self.permissions_ok
    }

    /// Get human-readable status for GUI
    pub fn status_message(&self) -> String {
        if self.is_ready() {
            "All systems ready".to_string()
        } else {
            let mut issues = vec![];
            if !self.claude_ok {
                issues.push("Claude Code not installed");
            }
            if !self.permissions_ok {
                issues.push("Permissions required");
            }
            issues.join(", ")
        }
    }

    /// Get detailed instructions for fixing issues
    pub fn fix_instructions(&self) -> Vec<(String, String)> {
        let mut instructions = vec![];

        if !self.claude_ok {
            instructions.push((
                "Install Claude Code".to_string(),
                "Windows PowerShell:\n  irm https://claude.ai/install.ps1 | iex\n\nmacOS / Linux:\n  curl -fsSL https://claude.ai/install.sh | bash".to_string(),
            ));
        }

        if !self.permissions_ok {
            if let Some(ref err) = self.permission_error {
                instructions.push((
                    "Grant Permissions".to_string(),
                    err.clone(),
                ));
            }
        }

        instructions
    }
}

/// Cached Claude Code path and version (populated on first successful find).
/// Only successful finds are cached — failed lookups re-probe so the setup
/// loop can detect a fresh install.
static CLAUDE_PATH: OnceCell<(String, String)> = OnceCell::const_new();

/// Returns the resolved Claude binary path (e.g. "claude.cmd" on Windows),
/// falling back to "claude" if not yet resolved via preflight.
pub fn resolved_claude_binary() -> String {
    CLAUDE_PATH
        .get()
        .map(|(path, _)| path.clone())
        .unwrap_or_else(|| "claude".to_string())
}

/// Check if Claude Code is installed, searching common locations.
/// Successful finds are cached so subsequent calls return instantly.
/// Failed lookups re-probe each time (setup loop can detect fresh install).
async fn check_claude() -> (bool, Option<String>, Option<String>) {
    // Return cached result if we already found Claude
    if let Some((path, version)) = CLAUDE_PATH.get() {
        return (true, Some(path.clone()), Some(version.clone()));
    }

    let home = crate::platform::home_dir().unwrap_or_default();
    let candidates = crate::platform::claude_binary_candidates(&home);

    for path in &candidates {
        let mut cmd = tokio::process::Command::new(path);
        cmd.arg("--version")
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null());
        // Suppress the flash of a console window on Windows when probing .cmd files
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            cmd.creation_flags(0x08000000); // CREATE_NO_WINDOW
        }
        if let Ok(output) = cmd.output().await {
            if output.status.success() {
                let version = String::from_utf8_lossy(&output.stdout).trim().to_string();
                let _ = CLAUDE_PATH.set((path.clone(), version.clone()));
                return (true, Some(path.clone()), Some(version));
            }
        }
    }

    (false, None, None)
}

/// Check macOS permissions for running terminal commands from GUI.
/// On Windows this check is not needed — always returns ok.
async fn check_permissions() -> (bool, Option<String>) {
    #[cfg(windows)]
    return (true, None);

    #[cfg(not(windows))]
    {
        // Test: Can we execute basic commands?
        let basic_test = tokio::process::Command::new("echo")
            .arg("test")
            .output()
            .await
            .map(|o| o.status.success())
            .unwrap_or(false);

        if !basic_test {
            return (false, Some(
                "Cannot execute commands.\n\n\
                 Go to: System Settings → Privacy & Security → Developer Tools\n\
                 Enable Termopus in the list.".to_string()
            ));
        }

        (true, None)
    }
}

/// Run complete pre-flight check
pub async fn preflight_check() -> PreflightResult {
    let (claude_ok, claude_path, claude_version) = check_claude().await;
    let (permissions_ok, permission_error) = check_permissions().await;

    PreflightResult {
        claude_ok,
        permissions_ok,
        claude_version,
        claude_path,
        permission_error,
    }
}

/// Run preflight and return error if not ready
pub async fn ensure_preflight() -> Result<PreflightResult> {
    let result = preflight_check().await;

    if !result.is_ready() {
        let instructions = result.fix_instructions();
        let msg = instructions
            .iter()
            .map(|(title, desc)| format!("{}:\n{}", title, desc))
            .collect::<Vec<_>>()
            .join("\n\n");

        anyhow::bail!("Setup required:\n\n{}", msg);
    }

    Ok(result)
}
