use anyhow::{Context, Result};
use std::path::PathBuf;

/// On Unix, use /tmp/ (not env::temp_dir()) because on macOS $TMPDIR
/// varies per process (/var/folders/.../T/) causing path mismatches.
pub fn ipc_base() -> PathBuf {
    PathBuf::from("/tmp")
}

pub fn home_dir() -> Option<String> {
    std::env::var("HOME").ok()
}

pub fn send_interrupt(pid: u32) -> Result<()> {
    let ret = unsafe { libc::kill(pid as i32, libc::SIGINT) };
    if ret != 0 {
        anyhow::bail!("kill(SIGINT) failed: {}", std::io::Error::last_os_error());
    }
    Ok(())
}

pub fn acquire_file_lock(path: &std::path::Path) -> Result<std::fs::File> {
    use std::os::unix::io::AsRawFd;
    let lock_file = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .open(path)?;
    let ret = unsafe { libc::flock(lock_file.as_raw_fd(), libc::LOCK_EX) };
    if ret != 0 {
        anyhow::bail!("flock failed: {}", std::io::Error::last_os_error());
    }
    Ok(lock_file)
}

pub async fn open_terminal(cmd: &str) -> Result<tokio::process::Child> {
    #[cfg(target_os = "macos")]
    {
        let apple_script = format!(
            "tell application \"Terminal\" to do script \"{}\"",
            cmd
        );
        tokio::process::Command::new("osascript")
            .args(["-e", &apple_script])
            .spawn()
            .context("Failed to launch Terminal.app via osascript")
    }
    #[cfg(not(target_os = "macos"))]
    {
        // Try common terminal emulators on Linux
        if let Ok(child) = tokio::process::Command::new("x-terminal-emulator")
            .args(["-e", cmd])
            .spawn()
        {
            return Ok(child);
        }
        tokio::process::Command::new("xterm")
            .args(["-e", cmd])
            .spawn()
            .context("Failed to launch terminal (tried x-terminal-emulator, xterm)")
    }
}

pub async fn kill_by_pattern(pattern: &str) -> Result<()> {
    let _ = tokio::process::Command::new("pkill")
        .args(["-f", pattern])
        .status()
        .await;
    Ok(())
}

pub fn open_folder(path: &std::path::Path) {
    #[cfg(target_os = "macos")]
    let _ = std::process::Command::new("open").arg(path).spawn();
    #[cfg(not(target_os = "macos"))]
    let _ = std::process::Command::new("xdg-open").arg(path).spawn();
}

pub fn open_url(url: &str) {
    #[cfg(target_os = "macos")]
    let _ = std::process::Command::new("open").arg(url).spawn();
    #[cfg(not(target_os = "macos"))]
    let _ = std::process::Command::new("xdg-open").arg(url).spawn();
}

pub fn find_in_path(binary_name: &str) -> Option<String> {
    let output = std::process::Command::new("which")
        .arg(binary_name)
        .output()
        .ok()?;
    if output.status.success() {
        let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if !path.is_empty() { Some(path) } else { None }
    } else {
        None
    }
}

pub fn path_separator() -> &'static str {
    ":"
}

pub fn extra_path_dirs(home: &str) -> Vec<String> {
    vec![
        format!("{}/.local/bin", home),
        format!("{}/.cargo/bin", home),
        "/opt/homebrew/bin".to_string(),
        "/opt/homebrew/sbin".to_string(),
        "/usr/local/bin".to_string(),
        format!("{}/bin", home),
        format!("{}/.npm-global/bin", home),
        "/usr/local/opt/node/bin".to_string(),
    ]
}

pub fn claude_binary_candidates(home: &str) -> Vec<String> {
    vec![
        "claude".to_string(),
        format!("{}/.local/bin/claude", home),
        format!("{}/.cargo/bin/claude", home),
        "/usr/local/bin/claude".to_string(),
        "/opt/homebrew/bin/claude".to_string(),
        format!("{}/.npm-global/bin/claude", home),
        "/usr/local/opt/node/bin/claude".to_string(),
    ]
}

pub unsafe fn lock_memory(ptr: *const u8, len: usize) {
    libc::mlock(ptr as *const libc::c_void, len);
}

pub fn create_dir_link(original: &std::path::Path, link: &std::path::Path) -> Result<()> {
    std::os::unix::fs::symlink(original, link)?;
    Ok(())
}

pub fn is_link(path: &std::path::Path) -> bool {
    path.symlink_metadata().map(|m| m.is_symlink()).unwrap_or(false)
}

pub fn quote_shell_path(path: &str) -> String {
    if path.contains(' ') {
        format!("'{}'", path)
    } else {
        path.to_string()
    }
}

pub fn secure_create_dir(path: &std::path::Path) -> std::io::Result<()> {
    use std::os::unix::fs::DirBuilderExt;
    let mut builder = std::fs::DirBuilder::new();
    builder.recursive(true).mode(0o700);
    builder.create(path)
}
