//! macOS Touch ID integration via LocalAuthentication framework.
//! On non-macOS or when Touch ID is unavailable, returns appropriate fallback.

use anyhow::Result;

/// Returns true if Touch ID hardware is available on this system.
pub fn is_available() -> bool {
    #[cfg(not(target_os = "macos"))]
    {
        return false;
    }

    #[cfg(target_os = "macos")]
    {
        check_availability_sync()
    }
}

#[cfg(target_os = "macos")]
fn check_availability_sync() -> bool {
    use std::process::Command;

    let script = r#"
        use framework "LocalAuthentication"
        set ctx to current application's LAContext's alloc()'s init()
        set {canEval, theError} to ctx's canEvaluatePolicy:1 |error|:(reference)
        if canEval then
            return "available"
        else
            return "unavailable"
        end if
    "#;

    let output = Command::new("osascript")
        .arg("-l").arg("AppleScript")
        .arg("-e").arg(script)
        .output();

    match output {
        Ok(out) => String::from_utf8_lossy(&out.stdout).trim() == "available",
        Err(_) => false,
    }
}

/// Prompt the user for Touch ID authentication.
/// Returns Ok(true) if authenticated, Ok(false) if denied/cancelled.
/// On non-macOS, returns Ok(true) to skip (PIN is the gate on other platforms).
pub async fn prompt_touch_id(reason: &str) -> Result<bool> {
    #[cfg(not(target_os = "macos"))]
    {
        let _ = reason;
        return Ok(true); // Not macOS — skip
    }

    #[cfg(target_os = "macos")]
    {
        let reason = reason.to_string();
        tokio::task::spawn_blocking(move || prompt_touch_id_sync(&reason)).await?
    }
}

#[cfg(target_os = "macos")]
fn prompt_touch_id_sync(reason: &str) -> Result<bool> {
    use std::process::{Command, Stdio};
    use std::io::Write;

    // AppleScript's ObjC bridge cannot call evaluatePolicy:localizedReason:reply:
    // (async block callback). Use Swift which handles it natively with a semaphore.
    let script = format!(
        r#"
import LocalAuthentication
import Foundation

let ctx = LAContext()
var error: NSError?
guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {{
    print("unavailable")
    exit(0)
}}
let sema = DispatchSemaphore(value: 0)
var result = "denied"
ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "{}") {{ success, _ in
    result = success ? "ok" : "denied"
    sema.signal()
}}
sema.wait()
print(result)
"#,
        reason.replace('\\', "\\\\").replace('"', "\\\"")
    );

    let mut child = Command::new("swift")
        .arg("-")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;

    if let Some(ref mut stdin) = child.stdin {
        stdin.write_all(script.as_bytes())?;
    }
    // Drop stdin so swift sees EOF and starts compiling
    child.stdin.take();

    let output = child.wait_with_output()?;
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();

    match stdout.as_str() {
        "ok" => Ok(true),
        "denied" => Ok(false),
        "unavailable" => {
            tracing::info!("Touch ID unavailable — falling back to PIN");
            Ok(false)
        }
        _ => {
            tracing::warn!("Touch ID unexpected: {} (stderr: {})",
                stdout, String::from_utf8_lossy(&output.stderr));
            Ok(false)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_is_available_returns_bool() {
        // is_available() must return a bool without panicking.
        // On macOS it shells out to osascript; on other platforms it returns false.
        let result = is_available();
        // Both true and false are valid; the key assertion is that it compiles
        // and runs without panicking.
        let _: bool = result;
    }

    #[test]
    fn test_is_available_on_current_platform() {
        // Verify is_available() does not panic on the current platform.
        // On non-macOS this is always false; on macOS it may be true or false
        // depending on hardware.
        let _ = is_available();
    }

    #[tokio::test]
    async fn test_prompt_touch_id_non_interactive() {
        // On non-macOS, prompt_touch_id returns Ok(true) immediately (no UI).
        // On macOS in a non-interactive CI environment osascript may return
        // "denied" or "unavailable", but the call must not panic or return Err
        // due to a missing function / compile error.
        let result = prompt_touch_id("test reason").await;
        // The function must return a Result<bool> — we only verify it doesn't
        // propagate a spawn_blocking join error (task panic).
        match result {
            Ok(_authenticated) => {}  // Ok — any bool value is acceptable
            Err(e) => {
                // On macOS CI the osascript exit / IO error path is acceptable;
                // we just make sure it isn't a panic (JoinError).
                let msg = e.to_string();
                assert!(
                    !msg.contains("task panicked"),
                    "prompt_touch_id must not panic: {msg}"
                );
            }
        }
    }
}
