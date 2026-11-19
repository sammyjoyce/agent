//! Every child process starts under one process-wide lock.
//!
//! macOS has no `pipe2`, so std creates each stdio pipe and only then marks it
//! close-on-exec. A child that another thread starts in between inherits the
//! pipe's write end and holds it after the intended child exits, so the reader
//! never sees end of file. While every start holds this lock, no start can
//! fall inside another start's pipe setup.

use std::{
    future::Future,
    io,
    process::{ExitStatus, Output, Stdio},
    sync::{Mutex, PoisonError},
};

static CHILD_START: Mutex<()> = Mutex::new(());

fn start_alone<T>(start: impl FnOnce() -> io::Result<T>) -> io::Result<T> {
    let _alone = CHILD_START.lock().unwrap_or_else(PoisonError::into_inner);
    start()
}

/// Runs `check` while no child is starting. A starting child holds a copy of
/// every descriptor in this process until its exec, so a lock that this
/// process has released can still look held while another thread starts one.
#[cfg(test)]
pub(crate) fn while_no_child_starts<T>(check: impl FnOnce() -> T) -> T {
    let _alone = CHILD_START.lock().unwrap_or_else(PoisonError::into_inner);
    check()
}

pub trait SerializedSpawn {
    fn spawn_serialized(&mut self) -> io::Result<std::process::Child>;

    /// Captures stdout and stderr and gives the child no input, whatever the
    /// command set before.
    fn output_serialized(&mut self) -> io::Result<Output>;

    fn status_serialized(&mut self) -> io::Result<ExitStatus>;
}

impl SerializedSpawn for std::process::Command {
    #[allow(clippy::disallowed_methods)]
    fn spawn_serialized(&mut self) -> io::Result<std::process::Child> {
        start_alone(|| self.spawn())
    }

    fn output_serialized(&mut self) -> io::Result<Output> {
        self.stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn_serialized()?
            .wait_with_output()
    }

    fn status_serialized(&mut self) -> io::Result<ExitStatus> {
        self.spawn_serialized()?.wait()
    }
}

pub trait SerializedTokioSpawn {
    fn spawn_serialized(&mut self) -> io::Result<tokio::process::Child>;

    /// Captures stdout and stderr, like `tokio::process::Command::output`.
    fn output_serialized(&mut self) -> impl Future<Output = io::Result<Output>> + Send + 'static;

    fn status_serialized(
        &mut self,
    ) -> impl Future<Output = io::Result<ExitStatus>> + Send + 'static;
}

impl SerializedTokioSpawn for tokio::process::Command {
    #[allow(clippy::disallowed_methods)]
    fn spawn_serialized(&mut self) -> io::Result<tokio::process::Child> {
        start_alone(|| self.spawn())
    }

    fn output_serialized(&mut self) -> impl Future<Output = io::Result<Output>> + Send + 'static {
        let child = self
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn_serialized();
        async { child?.wait_with_output().await }
    }

    fn status_serialized(
        &mut self,
    ) -> impl Future<Output = io::Result<ExitStatus>> + Send + 'static {
        let child = self.spawn_serialized();
        async {
            let mut child = child?;
            drop((child.stdin.take(), child.stdout.take(), child.stderr.take()));
            child.wait().await
        }
    }
}
