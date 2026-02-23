use anyhow::{Context, Result};
use std::process::Stdio;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{Child, Command};

/// Manages a Cloudflare Tunnel (`cloudflared`) subprocess.
///
/// The tunnel provides secure, outbound-only connectivity from the local
/// machine to the Cloudflare edge, without exposing any open ports.
///
/// # Usage
///
/// ```no_run
/// use termopus_bridge::relay::tunnel::CloudflareTunnel;
///
/// # async fn example() -> anyhow::Result<()> {
/// let tunnel = CloudflareTunnel::start("my-tunnel", 8765).await?;
/// // ... use the tunnel ...
/// tunnel.stop().await?;
/// # Ok(())
/// # }
/// ```
pub struct CloudflareTunnel {
    child: Child,
    tunnel_name: String,
}

impl CloudflareTunnel {
    /// Start a named Cloudflare Tunnel pointing at the given local port.
    ///
    /// Requires `cloudflared` to be installed and authenticated
    /// (`cloudflared tunnel login`).
    ///
    /// # Arguments
    ///
    /// * `tunnel_name` - The name of the tunnel (must be pre-created with
    ///   `cloudflared tunnel create <name>`)
    /// * `local_port` - The local TCP port to expose through the tunnel
    /// Maximum time to wait for the tunnel to become ready.
    const STARTUP_TIMEOUT: Duration = Duration::from_secs(30);

    pub async fn start(tunnel_name: &str, local_port: u16) -> Result<Self> {
        tracing::info!(
            "Starting Cloudflare Tunnel '{}' on port {}",
            tunnel_name,
            local_port
        );

        let mut child = Command::new("cloudflared")
            .arg("tunnel")
            .arg("--url")
            .arg(format!("http://localhost:{}", local_port))
            .arg("run")
            .arg(tunnel_name)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .context("Failed to start cloudflared - is it installed?")?;

        tracing::info!("Cloudflare Tunnel '{}' started (pid: {:?})", tunnel_name, child.id());

        // Wait for the tunnel to report it's connected
        Self::wait_for_ready(&mut child).await?;

        Ok(Self {
            child,
            tunnel_name: tunnel_name.to_string(),
        })
    }

    /// Start a quick tunnel (no pre-configuration needed).
    ///
    /// This creates a temporary tunnel with a random hostname, useful for
    /// development and testing.
    pub async fn start_quick(local_port: u16) -> Result<Self> {
        tracing::info!(
            "Starting quick Cloudflare Tunnel on port {}",
            local_port
        );

        let mut child = Command::new("cloudflared")
            .arg("tunnel")
            .arg("--url")
            .arg(format!("http://localhost:{}", local_port))
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .context("Failed to start cloudflared - is it installed?")?;

        tracing::info!("Quick Cloudflare Tunnel started (pid: {:?})", child.id());

        // Wait for the tunnel to report it's connected
        Self::wait_for_ready(&mut child).await?;

        Ok(Self {
            child,
            tunnel_name: "quick-tunnel".to_string(),
        })
    }

    /// Get the tunnel name.
    pub fn name(&self) -> &str {
        &self.tunnel_name
    }

    /// Check if the tunnel process is still running.
    pub async fn is_running(&mut self) -> bool {
        match self.child.try_wait() {
            Ok(None) => true,   // Still running
            Ok(Some(_)) => false, // Exited
            Err(_) => false,      // Error checking
        }
    }

    /// Wait for the `cloudflared` process to report that the tunnel is ready.
    ///
    /// Reads stderr line by line looking for indicators that the tunnel
    /// has successfully connected:
    /// - "Connection ... registered" (named tunnels)
    /// - "https://" URL in output (quick tunnels)
    /// - "Registered tunnel connection" (another variant)
    ///
    /// Times out after [`Self::STARTUP_TIMEOUT`].
    async fn wait_for_ready(child: &mut Child) -> Result<()> {
        let stderr = child
            .stderr
            .take()
            .context("Failed to capture cloudflared stderr")?;

        let mut reader = BufReader::new(stderr).lines();

        let result = tokio::time::timeout(Self::STARTUP_TIMEOUT, async {
            while let Ok(Some(line)) = reader.next_line().await {
                tracing::debug!("[cloudflared] {}", line);

                let lower = line.to_lowercase();
                if lower.contains("registered tunnel connection")
                    || lower.contains("connection registered")
                    || lower.contains("connector connected")
                    || (lower.contains("https://") && lower.contains(".trycloudflare.com"))
                {
                    tracing::info!("Cloudflare Tunnel is ready: {}", line);
                    return Ok(());
                }

                // Check for fatal errors
                if lower.contains("error") && lower.contains("failed to connect") {
                    return Err(anyhow::anyhow!(
                        "cloudflared failed to connect: {}",
                        line
                    ));
                }
            }
            Err(anyhow::anyhow!(
                "cloudflared process exited before tunnel was ready"
            ))
        })
        .await;

        match result {
            Ok(inner) => inner,
            Err(_) => {
                tracing::warn!(
                    "Cloudflare Tunnel startup timed out after {:?} — proceeding anyway",
                    Self::STARTUP_TIMEOUT
                );
                Ok(())
            }
        }
    }

    /// Stop the tunnel by killing the `cloudflared` process.
    pub async fn stop(mut self) -> Result<()> {
        tracing::info!("Stopping Cloudflare Tunnel '{}'", self.tunnel_name);
        self.child
            .kill()
            .await
            .context("Failed to kill cloudflared process")?;
        self.child
            .wait()
            .await
            .context("Failed to wait for cloudflared exit")?;
        tracing::info!("Cloudflare Tunnel '{}' stopped", self.tunnel_name);
        Ok(())
    }
}

/// Check if `cloudflared` is installed and available in PATH.
pub async fn is_cloudflared_installed() -> bool {
    Command::new("cloudflared")
        .arg("version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .await
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Get the installed version of `cloudflared`.
pub async fn cloudflared_version() -> Result<String> {
    let output = Command::new("cloudflared")
        .arg("version")
        .output()
        .await
        .context("Failed to run cloudflared version")?;

    let version = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if version.is_empty() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        Ok(stderr)
    } else {
        Ok(version)
    }
}

/// Automatically kill the cloudflared process when dropped.
/// This ensures orphaned tunnel processes don't persist after the bridge exits.
impl Drop for CloudflareTunnel {
    fn drop(&mut self) {
        tracing::info!("Dropping CloudflareTunnel, killing process: {}", self.tunnel_name);
        // Use start_kill() which is non-async and doesn't wait
        let _ = self.child.start_kill();
    }
}
