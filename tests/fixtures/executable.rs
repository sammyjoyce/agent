//! Executable fixtures for tests that share a process with other tests.

use agent_cli::serialized_spawn::SerializedSpawn;
use std::{
    fs,
    io::Write,
    os::unix::fs::PermissionsExt,
    path::Path,
    process::{Command, Stdio},
};

/// Creates `path` as a private executable without opening it in this process.
///
/// Linux refuses to execute a file that any process holds open for writing
/// (ETXTBSY). A spawn on a sibling test thread copies this process's open
/// descriptors into its child, and the child keeps them until it calls exec.
/// `tee` holds the only write descriptor and exits before this returns.
pub fn write_executable(path: &Path, content: &str) {
    let mut writer = Command::new("tee")
        .arg(path)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .spawn_serialized()
        .unwrap();
    writer
        .stdin
        .take()
        .unwrap()
        .write_all(content.as_bytes())
        .unwrap();
    assert!(writer.wait().unwrap().success());
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
}
