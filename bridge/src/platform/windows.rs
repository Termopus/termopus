use anyhow::{Context, Result};
use std::path::PathBuf;

/// On Windows, use %TEMP%\Termopus. std::env::temp_dir() is consistent
/// on Windows (unlike macOS), so it's safe to use directly.
pub fn ipc_base() -> PathBuf {
    std::env::temp_dir().join("Termopus")
}

pub fn home_dir() -> Option<String> {
    std::env::var("USERPROFILE").ok()
}

pub fn send_interrupt(pid: u32) -> Result<()> {
    // On Windows, use taskkill which is reliable across all process types.
    // GenerateConsoleCtrlEvent requires the target to be a process group
    // leader (CREATE_NEW_PROCESS_GROUP), which we can't guarantee.
    let status = std::process::Command::new("taskkill")
        .args(["/PID", &pid.to_string()])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()?;
    if !status.success() {
        anyhow::bail!("taskkill failed for pid {}", pid);
    }
    Ok(())
}

pub fn acquire_file_lock(path: &std::path::Path) -> Result<std::fs::File> {
    use std::os::windows::io::AsRawHandle;
    let lock_file = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .open(path)?;
    let handle = lock_file.as_raw_handle();
    let mut overlapped: windows_sys::Win32::System::IO::OVERLAPPED = unsafe { std::mem::zeroed() };
    let ret = unsafe {
        windows_sys::Win32::Storage::FileSystem::LockFileEx(
            handle as _,
            windows_sys::Win32::Storage::FileSystem::LOCKFILE_EXCLUSIVE_LOCK,
            0,
            u32::MAX,
            u32::MAX,
            &mut overlapped,
        )
    };
    if ret == 0 {
        anyhow::bail!("LockFileEx failed: {}", std::io::Error::last_os_error());
    }
    Ok(lock_file)
}

pub async fn open_terminal(cmd: &str) -> Result<tokio::process::Child> {
    // Try Windows Terminal first, fallback to cmd.exe
    if let Ok(child) = tokio::process::Command::new("wt.exe")
        .args(["cmd", "/k", cmd])
        .spawn()
    {
        return Ok(child);
    }
    // Fallback for systems without Windows Terminal (pre-20H2)
    tokio::process::Command::new("cmd.exe")
        .args(["/c", "start", "cmd", "/k", cmd])
        .spawn()
        .context("Failed to launch terminal (tried wt.exe and cmd.exe)")
}

pub async fn kill_by_pattern(pattern: &str) -> Result<()> {
    // Native Win32 API: enumerate all processes, read command lines, terminate matches.
    // Avoids wmic (deprecated/removed in Windows 11 24H2+) and PowerShell dependency.
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, Process32First, Process32Next,
        PROCESSENTRY32, TH32CS_SNAPPROCESS,
    };
    use windows_sys::Win32::System::Threading::{
        OpenProcess, TerminateProcess, PROCESS_QUERY_INFORMATION, PROCESS_TERMINATE,
    };
    use windows_sys::Win32::Foundation::CloseHandle;

    unsafe {
        let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if snapshot == windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE {
            return Ok(());
        }

        let mut entry: PROCESSENTRY32 = std::mem::zeroed();
        entry.dwSize = std::mem::size_of::<PROCESSENTRY32>() as u32;

        if Process32First(snapshot, &mut entry) == 0 {
            CloseHandle(snapshot);
            return Ok(());
        }

        let pattern_lower = pattern.to_lowercase();

        loop {
            let exe_name = std::ffi::CStr::from_ptr(entry.szExeFile.as_ptr() as *const i8)
                .to_string_lossy()
                .to_lowercase();

            if exe_name.contains(&pattern_lower) {
                let proc = OpenProcess(
                    PROCESS_QUERY_INFORMATION | PROCESS_TERMINATE,
                    0,
                    entry.th32ProcessID,
                );
                if proc != 0 {
                    TerminateProcess(proc, 1);
                    CloseHandle(proc);
                }
            }

            if Process32Next(snapshot, &mut entry) == 0 {
                break;
            }
        }

        CloseHandle(snapshot);
    }
    Ok(())
}

pub fn open_folder(path: &std::path::Path) {
    let _ = std::process::Command::new("explorer").arg(path).spawn();
}

pub fn open_url(url: &str) {
    let _ = std::process::Command::new("explorer").arg(url).spawn();
}

pub fn find_in_path(binary_name: &str) -> Option<String> {
    let output = std::process::Command::new("where.exe")
        .arg(binary_name)
        .output()
        .ok()?;
    if output.status.success() {
        // `where` may return multiple lines; take the first
        let path = String::from_utf8_lossy(&output.stdout)
            .lines()
            .next()?
            .trim()
            .to_string();
        if !path.is_empty() { Some(path) } else { None }
    } else {
        None
    }
}

pub fn path_separator() -> &'static str {
    ";"
}

pub fn extra_path_dirs(home: &str) -> Vec<String> {
    vec![
        // Native installer puts claude.exe here
        format!("{}\\.local\\bin", home),
        format!("{}\\AppData\\Local\\Programs\\claude", home),
        format!("{}\\AppData\\Roaming\\npm", home),
        format!("{}\\.cargo\\bin", home),
        format!("{}\\scoop\\shims", home),
    ]
}

pub fn claude_binary_candidates(home: &str) -> Vec<String> {
    vec![
        // Native installer (recommended) — %USERPROFILE%\.local\bin\claude.exe
        format!("{}\\.local\\bin\\claude.exe", home),
        // Plain name — works if %USERPROFILE%\.local\bin is already in PATH
        "claude.exe".to_string(),
        // WinGet install location
        format!("{}\\AppData\\Local\\Programs\\claude\\claude.exe", home),
        // Scoop
        format!("{}\\scoop\\shims\\claude.exe", home),
        // Legacy npm (deprecated but still on some machines)
        format!("{}\\AppData\\Roaming\\npm\\claude.cmd", home),
    ]
}

pub unsafe fn lock_memory(ptr: *const u8, len: usize) {
    windows_sys::Win32::System::Memory::VirtualLock(ptr as *mut _, len);
}

pub fn create_dir_link(original: &std::path::Path, link: &std::path::Path) -> Result<()> {
    // Try symlink first (works if Developer Mode is enabled or running as admin).
    // Fall back to NTFS junction via `cmd /c mklink /J` which works without elevation.
    if std::os::windows::fs::symlink_dir(original, link).is_ok() {
        return Ok(());
    }
    let status = std::process::Command::new("cmd")
        .args([
            "/c", "mklink", "/J",
            &link.to_string_lossy(),
            &original.to_string_lossy(),
        ])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()?;
    if !status.success() {
        anyhow::bail!(
            "Failed to create junction {} -> {} (symlink also failed — Developer Mode may be required)",
            link.display(), original.display()
        );
    }
    Ok(())
}

pub fn is_link(path: &std::path::Path) -> bool {
    // Detects both symlinks and NTFS junctions (both are reparse points)
    path.symlink_metadata()
        .map(|m| m.file_type().is_symlink())
        .unwrap_or(false)
}

pub fn quote_shell_path(path: &str) -> String {
    // Claude Code runs hooks through bash (sh -c), so backslashes get eaten
    // as escape characters. Convert to forward slashes which bash handles fine.
    let path = path.replace('\\', "/");
    if path.contains(' ') {
        format!("\"{}\"", path)
    } else {
        path
    }
}

pub fn secure_create_dir(path: &std::path::Path) -> std::io::Result<()> {
    // Windows default ACLs inherit from parent and are sufficient for user-private dirs.
    std::fs::create_dir_all(path)
}
