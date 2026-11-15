//! Executable fixtures for tests that share a process with other tests.

use std::{fs, os::unix::fs::PermissionsExt, path::Path};

/// Creates `path` as a private executable.
pub fn write_executable(path: &Path, content: &str) {
    fs::write(path, content).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
}
