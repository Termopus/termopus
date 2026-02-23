use anyhow::Result;
use notify::{Config, Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use std::fs;
use std::path::PathBuf;
use std::sync::mpsc;
use tokio::sync::mpsc as tokio_mpsc;

use super::{HookDirectory, HookEvent};

/// Watches the events directory for new hook event files.
/// Sends parsed HookEvent objects through a tokio channel.
///
/// The writer (termopus-hook) uses atomic writes (write .tmp, rename to .json)
/// so files are always complete when they appear as .json.
pub struct HookWatcher {
    _watcher: RecommendedWatcher,
}

impl HookWatcher {
    /// Start watching the events directory. Returns a receiver for HookEvent objects.
    pub fn start(hook_dir: &HookDirectory) -> Result<(Self, tokio_mpsc::Receiver<HookEvent>)> {
        let (tx, rx) = tokio_mpsc::channel::<HookEvent>(64);
        let events_dir = hook_dir.events_dir.clone();

        // Set up filesystem watcher FIRST so no events are missed
        let (fs_tx, fs_rx) = mpsc::channel::<notify::Result<Event>>();
        let mut watcher = RecommendedWatcher::new(fs_tx, Config::default())?;
        watcher.watch(&events_dir, RecursiveMode::NonRecursive)?;

        // Then process any existing files (in case bridge restarted).
        // The watcher may also fire events for these — read_and_forward
        // handles the overlap via NotFound → silent skip.
        Self::process_existing_files(&events_dir, &tx)?;

        // Spawn blocking thread to read filesystem events and forward
        let tx_clone = tx.clone();
        std::thread::spawn(move || {
            for result in fs_rx {
                match result {
                    Ok(event) => {
                        // Match Create (macOS/FSEvents) and Rename-To (Linux/inotify)
                        // since the writer uses atomic tmp+rename.
                        let should_process = matches!(
                            event.kind,
                            EventKind::Create(_)
                                | EventKind::Modify(notify::event::ModifyKind::Name(_))
                        );
                        if should_process {
                            for path in &event.paths {
                                if path.extension().map_or(false, |e| e == "json") {
                                    if let Err(e) = Self::read_and_forward(path, &tx_clone) {
                                        tracing::error!(
                                            "Failed to process hook event {}: {}",
                                            path.display(),
                                            e
                                        );
                                    }
                                }
                            }
                        }
                    }
                    Err(e) => tracing::error!("Filesystem watch error: {}", e),
                }
            }
            tracing::info!("Hook watcher thread exiting");
        });

        Ok((Self { _watcher: watcher }, rx))
    }

    fn process_existing_files(
        events_dir: &PathBuf,
        tx: &tokio_mpsc::Sender<HookEvent>,
    ) -> Result<()> {
        if let Ok(entries) = fs::read_dir(events_dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().map_or(false, |e| e == "json") {
                    let _ = Self::read_and_forward(&path, tx);
                }
            }
        }
        Ok(())
    }

    fn read_and_forward(path: &std::path::Path, tx: &tokio_mpsc::Sender<HookEvent>) -> Result<()> {
        // Writer uses atomic tmp+rename, so the file is complete when it
        // appears as .json. No retry loop needed for partial writes.
        match fs::read_to_string(path) {
            Ok(content) => {
                match serde_json::from_str::<HookEvent>(&content) {
                    Ok(mut event) => {
                        let request_id = path
                            .file_stem()
                            .and_then(|s| s.to_str())
                            .and_then(|s| s.rsplit('-').next())
                            .unwrap_or("unknown")
                            .to_string();
                        event.request_id = request_id;

                        tracing::info!(
                            "Hook event: {} tool={:?} id={}",
                            event.hook_event_name,
                            event.tool_name,
                            event.request_id
                        );

                        // Delete the file after successful read
                        let _ = fs::remove_file(path);

                        if let Err(e) = tx.blocking_send(event) {
                            tracing::error!(
                                "Failed to forward hook event (channel closed?): {}",
                                e
                            );
                        }
                        Ok(())
                    }
                    Err(e) => {
                        tracing::error!(
                            "Corrupt hook event file {}: {}",
                            path.display(),
                            e
                        );
                        let _ = fs::remove_file(path);
                        Err(anyhow::anyhow!("JSON parse error: {}", e))
                    }
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                // File already processed/deleted by another handler (duplicate
                // notify event or overlap with process_existing_files).
                tracing::debug!("Hook event file already gone: {}", path.display());
                Ok(())
            }
            Err(e) => {
                tracing::error!("Failed to read hook event {}: {}", path.display(), e);
                let _ = fs::remove_file(path);
                Err(anyhow::anyhow!("File read error: {}", e))
            }
        }
    }
}
