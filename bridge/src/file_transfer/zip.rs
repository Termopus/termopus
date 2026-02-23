//! Auto-zip utility for outbox files.
//!
//! Rules:
//! - 1–3 files: send individually (no zip)
//! - 4+ files: bundle into a single zip
//! - Directories: always zip regardless of count

use anyhow::{Context, Result};
use std::fs::File;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use zip::write::FileOptions;
use zip::ZipWriter;

/// Categorise a batch of outbox paths into individual sends and zips.
///
/// Returns `(individual_files, zip_paths)`:
/// - `individual_files`: paths to send as-is (1–3 regular files)
/// - `zip_path`: if Some, a temp zip was created and should be sent then deleted
pub fn prepare_outbox_batch(paths: &[PathBuf], outbox_dir: &Path) -> Result<(Vec<PathBuf>, Option<PathBuf>)> {
    let mut files: Vec<PathBuf> = Vec::new();
    let mut dirs: Vec<PathBuf> = Vec::new();

    for p in paths {
        if p.is_dir() {
            dirs.push(p.clone());
        } else if p.is_file() {
            files.push(p.clone());
        }
    }

    // Directories: always zip each one
    // If there are directories mixed with files, zip everything together
    if !dirs.is_empty() {
        let zip_path = outbox_dir.join("_termopus_bundle.zip");
        let mut all_paths = dirs;
        all_paths.extend(files);
        zip_paths(&all_paths, &zip_path)?;
        return Ok((Vec::new(), Some(zip_path)));
    }

    // Files only: <=3 send individually, >3 zip
    if files.len() <= 3 {
        Ok((files, None))
    } else {
        let zip_path = outbox_dir.join("_termopus_bundle.zip");
        zip_paths(&files, &zip_path)?;
        Ok((Vec::new(), Some(zip_path)))
    }
}

/// Create a zip archive from a list of files and/or directories.
fn zip_paths(paths: &[PathBuf], output: &Path) -> Result<()> {
    let file = File::create(output).context("Failed to create zip file")?;
    let mut zip = ZipWriter::new(file);
    let options = FileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated);

    for path in paths {
        if path.is_dir() {
            add_directory_to_zip(&mut zip, path, path, options)?;
        } else if path.is_file() {
            let name = path.file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_else(|| "file".to_string());
            add_file_to_zip(&mut zip, path, &name, options)?;
        }
    }

    zip.finish().context("Failed to finalize zip")?;
    Ok(())
}

/// Add a single file to the zip with the given archive name.
fn add_file_to_zip<W: Write + std::io::Seek>(
    zip: &mut ZipWriter<W>,
    file_path: &Path,
    archive_name: &str,
    options: FileOptions,
) -> Result<()> {
    zip.start_file(archive_name, options)
        .context("Failed to start zip entry")?;
    let mut f = File::open(file_path).context("Failed to open file for zip")?;
    let mut buf = Vec::new();
    f.read_to_end(&mut buf).context("Failed to read file for zip")?;
    zip.write_all(&buf).context("Failed to write to zip")?;
    Ok(())
}

/// Recursively add a directory to the zip.
fn add_directory_to_zip<W: Write + std::io::Seek>(
    zip: &mut ZipWriter<W>,
    dir_path: &Path,
    base_path: &Path,
    options: FileOptions,
) -> Result<()> {
    let dir_name = base_path.file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "folder".to_string());

    for entry in walkdir::WalkDir::new(dir_path)
        .follow_links(false)
        .into_iter()
        .filter_map(|e| e.ok())
    {
        let entry_path = entry.path();
        if entry_path == dir_path {
            continue; // skip the root dir itself
        }

        // Skip symlinks to prevent exfiltrating files outside the outbox
        if entry.path_is_symlink() {
            continue;
        }

        // Build archive path: dirname/relative/path
        let relative = entry_path.strip_prefix(dir_path)
            .unwrap_or(entry_path);
        let archive_name = format!("{}/{}", dir_name, relative.to_string_lossy());

        if entry_path.is_file() {
            add_file_to_zip(zip, entry_path, &archive_name, options)?;
        }
        // zip crate doesn't require explicit directory entries
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn test_individual_files() {
        let dir = tempfile::tempdir().unwrap();
        let outbox = dir.path().join("outbox");
        fs::create_dir_all(&outbox).unwrap();

        // Create 2 files
        let f1 = outbox.join("a.txt");
        let f2 = outbox.join("b.txt");
        fs::write(&f1, "hello").unwrap();
        fs::write(&f2, "world").unwrap();

        let (individual, zip) = prepare_outbox_batch(&[f1.clone(), f2.clone()], &outbox).unwrap();
        assert_eq!(individual.len(), 2);
        assert!(zip.is_none());
    }

    #[test]
    fn test_four_files_zipped() {
        let dir = tempfile::tempdir().unwrap();
        let outbox = dir.path().join("outbox");
        fs::create_dir_all(&outbox).unwrap();

        let mut paths = Vec::new();
        for i in 0..4 {
            let p = outbox.join(format!("file_{}.txt", i));
            fs::write(&p, format!("content {}", i)).unwrap();
            paths.push(p);
        }

        let (individual, zip) = prepare_outbox_batch(&paths, &outbox).unwrap();
        assert!(individual.is_empty());
        assert!(zip.is_some());
        assert!(zip.unwrap().exists());
    }

    #[test]
    fn test_directory_always_zipped() {
        let dir = tempfile::tempdir().unwrap();
        let outbox = dir.path().join("outbox");
        fs::create_dir_all(&outbox).unwrap();

        // Create a subdirectory with files
        let subdir = outbox.join("my_folder");
        fs::create_dir_all(&subdir).unwrap();
        fs::write(subdir.join("inner.txt"), "inside").unwrap();

        let (individual, zip) = prepare_outbox_batch(&[subdir], &outbox).unwrap();
        assert!(individual.is_empty());
        assert!(zip.is_some());

        // Verify zip contains the file
        let zip_path = zip.unwrap();
        let zip_file = File::open(&zip_path).unwrap();
        let mut archive = zip::ZipArchive::new(zip_file).unwrap();
        assert!(archive.len() >= 1);
        let entry = archive.by_index(0).unwrap();
        assert!(entry.name().contains("inner.txt"));
    }

    #[test]
    fn test_three_files_individual() {
        let dir = tempfile::tempdir().unwrap();
        let outbox = dir.path().join("outbox");
        fs::create_dir_all(&outbox).unwrap();

        let mut paths = Vec::new();
        for i in 0..3 {
            let p = outbox.join(format!("f{}.txt", i));
            fs::write(&p, "x").unwrap();
            paths.push(p);
        }

        let (individual, zip) = prepare_outbox_batch(&paths, &outbox).unwrap();
        assert_eq!(individual.len(), 3);
        assert!(zip.is_none());
    }

    #[test]
    #[cfg(unix)]
    fn test_symlinks_excluded_from_zip() {
        let dir = tempfile::tempdir().unwrap();
        let outbox = dir.path().join("outbox");
        fs::create_dir_all(&outbox).unwrap();

        let subdir = outbox.join("project");
        fs::create_dir_all(&subdir).unwrap();
        fs::write(subdir.join("real.txt"), "safe content").unwrap();

        // Create a symlink pointing outside the outbox
        std::os::unix::fs::symlink("/etc/hosts", subdir.join("escape.txt")).unwrap();

        let (individual, zip) = prepare_outbox_batch(&[subdir], &outbox).unwrap();
        assert!(individual.is_empty());
        let zip_path = zip.unwrap();
        let zip_file = File::open(&zip_path).unwrap();
        let archive = zip::ZipArchive::new(zip_file).unwrap();

        // Verify: only real.txt is in the zip, not the symlink
        let names: Vec<_> = archive.file_names().collect();
        assert!(names.iter().any(|n| n.contains("real.txt")));
        assert!(!names.iter().any(|n| n.contains("escape")));
    }
}
