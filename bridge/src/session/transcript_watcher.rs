//! Watches a Claude JSONL transcript file and emits new messages.
//!
//! Used during handoff: bridge watches the transcript while the user
//! works interactively on the computer, forwarding updates to phone.

use std::path::PathBuf;
use std::io::{BufRead, BufReader, Seek, SeekFrom};
use std::fs::File;
use std::time::Duration;
use tokio::sync::mpsc;

use super::transcript::{parse_transcript_line, TranscriptMessage};

/// A parsed transcript message ready to send to phone.
pub type WatcherMessage = TranscriptMessage;

/// Start watching a transcript file for new entries.
///
/// Returns a receiver that emits new `TranscriptMessage`s as they're appended.
/// The watcher runs until the stop signal fires or the receiver is dropped.
pub fn watch_transcript(
    path: PathBuf,
    stop: tokio::sync::oneshot::Receiver<()>,
) -> mpsc::Receiver<WatcherMessage> {
    let (tx, rx) = mpsc::channel(64);

    tokio::task::spawn_blocking(move || {
        let mut file = match File::open(&path) {
            Ok(f) => f,
            Err(e) => {
                tracing::warn!("TranscriptWatcher: failed to open {:?}: {}", path, e);
                return;
            }
        };

        // Seek to end — we only want NEW entries
        if let Err(e) = file.seek(SeekFrom::End(0)) {
            tracing::warn!("TranscriptWatcher: seek failed: {}", e);
            return;
        }

        let mut reader = BufReader::new(file);
        let mut stop = stop;

        loop {
            // Check if we should stop
            match stop.try_recv() {
                Ok(()) | Err(tokio::sync::oneshot::error::TryRecvError::Closed) => {
                    tracing::info!("TranscriptWatcher: stopped");
                    return;
                }
                Err(tokio::sync::oneshot::error::TryRecvError::Empty) => {}
            }

            // Try reading new lines
            let mut line = String::new();
            match reader.read_line(&mut line) {
                Ok(0) => {
                    // No new data — wait and retry
                    std::thread::sleep(Duration::from_millis(500));
                    continue;
                }
                Ok(_) => {
                    let trimmed = line.trim();
                    if !trimmed.is_empty() {
                        if let Some(msg) = parse_transcript_line(trimmed) {
                            if tx.blocking_send(msg).is_err() {
                                // Receiver dropped — stop watching
                                return;
                            }
                        }
                    }
                    line.clear();
                }
                Err(e) => {
                    tracing::warn!("TranscriptWatcher: read error: {}", e);
                    std::thread::sleep(Duration::from_secs(1));
                    line.clear();
                }
            }
        }
    });

    rx
}
