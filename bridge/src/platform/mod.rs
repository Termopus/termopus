//! Platform abstraction layer.
//! All OS-specific code lives here — the rest of the codebase calls these functions.

#[cfg(unix)]
mod unix;
#[cfg(windows)]
mod windows;

#[cfg(unix)]
use unix as imp;
#[cfg(windows)]
use windows as imp;

use anyhow::Result;
use std::path::PathBuf;

/// Base directory for file-based IPC between bridge and hook binary.
pub fn ipc_base() -> PathBuf {
    imp::ipc_base()
}

/// Get the user's home directory.
/// Uses $HOME on Unix, %USERPROFILE% on Windows.
pub fn home_dir() -> Option<String> {
    imp::home_dir()
}

/// Get the user's home directory, falling back to temp dir if unset.
pub fn home_dir_or_temp() -> String {
    home_dir().unwrap_or_else(|| std::env::temp_dir().display().to_string())
}

/// Send SIGINT (Unix) or terminate (Windows) to interrupt a process.
pub fn send_interrupt(pid: u32) -> Result<()> {
    imp::send_interrupt(pid)
}

/// Acquire an exclusive file lock (blocking).
pub fn acquire_file_lock(path: &std::path::Path) -> Result<std::fs::File> {
    imp::acquire_file_lock(path)
}

/// Launch an interactive terminal running the given command.
pub async fn open_terminal(cmd: &str) -> Result<tokio::process::Child> {
    imp::open_terminal(cmd).await
}

/// Kill processes matching a command-line pattern (for takeback).
pub async fn kill_by_pattern(pattern: &str) -> Result<()> {
    imp::kill_by_pattern(pattern).await
}

/// Open a folder in the system file manager.
pub fn open_folder(path: &std::path::Path) {
    imp::open_folder(path)
}

/// Open a URL in the default browser.
pub fn open_url(url: &str) {
    imp::open_url(url)
}

/// Find a binary in PATH using the platform's tool (which/where).
pub fn find_in_path(binary_name: &str) -> Option<String> {
    imp::find_in_path(binary_name)
}

/// PATH environment variable separator (: on Unix, ; on Windows).
pub fn path_separator() -> &'static str {
    imp::path_separator()
}

/// Extra directories to add to PATH when launched from a GUI.
pub fn extra_path_dirs(home: &str) -> Vec<String> {
    imp::extra_path_dirs(home)
}

/// Candidate paths for finding the Claude binary.
pub fn claude_binary_candidates(home: &str) -> Vec<String> {
    imp::claude_binary_candidates(home)
}

/// Lock memory to prevent swapping (for crypto key material).
/// Best-effort — failure is not fatal.
pub unsafe fn lock_memory(ptr: *const u8, len: usize) {
    imp::lock_memory(ptr, len)
}

/// Create a directory symlink (Unix) or junction (Windows).
pub fn create_dir_link(original: &std::path::Path, link: &std::path::Path) -> Result<()> {
    imp::create_dir_link(original, link)
}

/// Check if a path is a symlink or junction.
pub fn is_link(path: &std::path::Path) -> bool {
    imp::is_link(path)
}

/// Quote a path for shell invocation.
/// Claude Code passes hook commands through sh -c (Unix) or cmd /c (Windows).
pub fn quote_shell_path(path: &str) -> String {
    imp::quote_shell_path(path)
}

/// Create directories with restricted permissions.
/// Unix: chmod 0o700 (owner-only). Windows: default ACLs (sufficient).
pub fn secure_create_dir(path: &std::path::Path) -> std::io::Result<()> {
    imp::secure_create_dir(path)
}
