//! Typed local status Unix sockets for non-coordinator Beep Boop daemons
//! (`maintain` workers and `failover follow` standbys).
//!
//! Each daemon answers `NativeCommand::Native { request: NativeRequest::ServiceStatus }`
//! with a `NativeEvent::ServiceStatus` frame followed by `NativeEvent::Done` — the exact
//! wire contract `serve` already exposes on `agent.sock` — so clients such as
//! `BeepBoopMenuBar` can inspect every local role without scraping process lists.

use std::{
    fs,
    io::{self, BufRead, BufReader, Read, Write},
    os::unix::{
        fs::{FileTypeExt, MetadataExt, PermissionsExt},
        io::AsRawFd,
        net::{UnixListener, UnixStream},
    },
    path::{Path, PathBuf},
    sync::{
        Arc, RwLock,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::Duration,
};

use anyhow::{Context, Result, bail, ensure};

use super::{NativeCommand, NativeEvent, NativeRequest, ServiceConnectionState, ServiceRole};
use crate::protocol::ErrorCode;

pub const WORKER_SOCKET_NAME: &str = "worker.sock";
pub const STANDBY_SOCKET_NAME: &str = "standby.sock";

const IO_TIMEOUT: Duration = Duration::from_secs(2);
const MAX_REQUEST_BYTES: usize = 4096;

/// Canonical path of the currently executing binary, when available.
pub(crate) fn current_executable_path() -> Option<String> {
    std::env::current_exe().ok().map(|path| {
        path.canonicalize()
            .unwrap_or(path)
            .to_string_lossy()
            .into_owned()
    })
}

#[derive(Clone, Debug)]
struct LocalStatusSnapshot {
    role: ServiceRole,
    coordinator_id: String,
    pid: u32,
    version: String,
    executable_path: Option<String>,
    state_dir: String,
    connection_state: ServiceConnectionState,
    target: Option<String>,
    node_name: Option<String>,
    applied_position: Option<u64>,
    detail: Option<String>,
}

impl LocalStatusSnapshot {
    fn to_event(&self) -> NativeEvent {
        NativeEvent::ServiceStatus {
            coordinator_id: self.coordinator_id.clone(),
            pid: self.pid,
            version: self.version.clone(),
            executable_path: self.executable_path.clone(),
            state_dir: self.state_dir.clone(),
            role: Some(self.role),
            connection_state: Some(self.connection_state),
            target: self.target.clone(),
            node_name: self.node_name.clone(),
            applied_position: self.applied_position,
            detail: self.detail.clone(),
        }
    }
}

struct StatusSocketOwner {
    path: PathBuf,
    device: u64,
    inode: u64,
}

impl StatusSocketOwner {
    fn bind(path: PathBuf) -> Result<(UnixListener, Self)> {
        match fs::symlink_metadata(&path) {
            Ok(metadata) => {
                ensure!(
                    metadata.file_type().is_socket(),
                    "Local status socket path {} contains a foreign non-socket; preserving it",
                    path.display()
                );
                // Refuse to replace a live listener owned by another active process.
                match UnixStream::connect(&path) {
                    Ok(_) => bail!(
                        "Another local Beep Boop status service is already listening at {}",
                        path.display()
                    ),
                    Err(error)
                        if matches!(
                            error.kind(),
                            io::ErrorKind::ConnectionRefused | io::ErrorKind::NotFound
                        ) =>
                    {
                        fs::remove_file(&path)?;
                    }
                    Err(error) => return Err(error.into()),
                }
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
        let listener = UnixListener::bind(&path)
            .with_context(|| format!("Could not bind local status socket {}", path.display()))?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
        let metadata = fs::symlink_metadata(&path)?;
        Ok((
            listener,
            Self {
                path,
                device: metadata.dev(),
                inode: metadata.ino(),
            },
        ))
    }
}

impl Drop for StatusSocketOwner {
    fn drop(&mut self) {
        if let Ok(metadata) = fs::symlink_metadata(&self.path)
            && metadata.file_type().is_socket()
            && metadata.dev() == self.device
            && metadata.ino() == self.inode
        {
            let _ = fs::remove_file(&self.path);
        }
    }
}

/// Background local Unix-socket status responder owned by a worker or standby daemon.
///
/// Unlinks its socket cleanly on `Drop` without affecting any other process's socket.
pub struct LocalStatusServer {
    state: Arc<RwLock<LocalStatusSnapshot>>,
    stopped: Arc<AtomicBool>,
    wake_tx: Option<UnixStream>,
    thread: Option<thread::JoinHandle<()>>,
}

impl LocalStatusServer {
    pub fn start_worker(state_dir: &Path, target: String) -> Result<Self> {
        let initial = LocalStatusSnapshot {
            role: ServiceRole::Worker,
            coordinator_id: String::new(),
            pid: std::process::id(),
            version: env!("CARGO_PKG_VERSION").to_owned(),
            executable_path: current_executable_path(),
            state_dir: state_dir.to_string_lossy().into_owned(),
            connection_state: ServiceConnectionState::Connecting,
            target: (!target.is_empty()).then_some(target),
            node_name: None,
            applied_position: None,
            detail: None,
        };
        Self::start(state_dir.join(WORKER_SOCKET_NAME), initial)
    }

    pub fn start_standby(state_dir: &Path, coordinator_id: String) -> Result<Self> {
        let initial = LocalStatusSnapshot {
            role: ServiceRole::Standby,
            coordinator_id,
            pid: std::process::id(),
            version: env!("CARGO_PKG_VERSION").to_owned(),
            executable_path: current_executable_path(),
            state_dir: state_dir.to_string_lossy().into_owned(),
            connection_state: ServiceConnectionState::Connecting,
            target: None,
            node_name: None,
            applied_position: None,
            detail: None,
        };
        Self::start(state_dir.join(STANDBY_SOCKET_NAME), initial)
    }

    fn start(socket_path: PathBuf, initial: LocalStatusSnapshot) -> Result<Self> {
        let (listener, owner) = StatusSocketOwner::bind(socket_path)?;
        listener
            .set_nonblocking(true)
            .context("Could not configure non-blocking local status listener")?;
        let (wake_rx, wake_tx) =
            UnixStream::pair().context("Could not create local status wakeup pipe")?;
        wake_rx
            .set_nonblocking(true)
            .context("Could not configure non-blocking local status wakeup pipe")?;
        let state = Arc::new(RwLock::new(initial));
        let stopped = Arc::new(AtomicBool::new(false));
        let worker_state = Arc::clone(&state);
        let worker_stopped = Arc::clone(&stopped);
        let thread = thread::Builder::new()
            .name("agent-local-status".into())
            .spawn(move || {
                serve_loop(listener, wake_rx, owner, worker_state, worker_stopped);
            })
            .context("Could not start local status listener thread")?;
        Ok(Self {
            state,
            stopped,
            wake_tx: Some(wake_tx),
            thread: Some(thread),
        })
    }

    pub fn set_worker_connected(&self, coordinator_id: String, node_name: String) {
        self.update(|snapshot| {
            snapshot.coordinator_id = coordinator_id;
            snapshot.node_name = Some(node_name);
            snapshot.connection_state = ServiceConnectionState::Connected;
            snapshot.detail = None;
        });
    }

    pub fn set_worker_reconnecting(&self, detail: String) {
        self.update(|snapshot| {
            snapshot.connection_state = ServiceConnectionState::Reconnecting;
            snapshot.detail = (!detail.trim().is_empty()).then_some(detail);
        });
    }

    pub fn set_standby_following(&self, applied_position: u64) {
        self.update(|snapshot| {
            snapshot.connection_state = ServiceConnectionState::Following;
            snapshot.applied_position = Some(applied_position);
            snapshot.detail = None;
        });
    }

    pub fn set_standby_unreachable(&self, detail: String) {
        self.update(|snapshot| {
            snapshot.connection_state = ServiceConnectionState::AuthorityUnreachable;
            snapshot.detail = (!detail.trim().is_empty()).then_some(detail);
        });
    }

    fn update(&self, mutate: impl FnOnce(&mut LocalStatusSnapshot)) {
        let mut guard = self
            .state
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        mutate(&mut guard);
    }
}

impl Drop for LocalStatusServer {
    fn drop(&mut self) {
        self.stopped.store(true, Ordering::SeqCst);
        // Signal the wakeup pipe so `poll()` exits immediately even if the socket
        // path on disk was deleted or replaced externally.
        if let Some(mut wake_tx) = self.wake_tx.take() {
            let _ = wake_tx.write_all(&[1]);
        }
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

fn serve_loop(
    listener: UnixListener,
    wake_rx: UnixStream,
    _owner: StatusSocketOwner,
    state: Arc<RwLock<LocalStatusSnapshot>>,
    stopped: Arc<AtomicBool>,
) {
    let mut fds = [
        libc::pollfd {
            fd: listener.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        },
        libc::pollfd {
            fd: wake_rx.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        },
    ];
    while !stopped.load(Ordering::SeqCst) {
        fds[0].revents = 0;
        fds[1].revents = 0;
        // SAFETY: `fds` points to 2 valid `pollfd` entries backed by open descriptors
        // owned by `listener` and `wake_rx` for the duration of this call.
        let ready = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, -1) };
        if ready < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            break;
        }
        if stopped.load(Ordering::SeqCst) || fds[1].revents != 0 {
            break;
        }
        if fds[0].revents & libc::POLLIN != 0 {
            loop {
                if stopped.load(Ordering::SeqCst) {
                    return;
                }
                match listener.accept() {
                    Ok((stream, _)) => {
                        let _ = stream.set_nonblocking(false);
                        let _ = handle_client(stream, &state);
                    }
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                    Err(_) => break,
                }
            }
        }
    }
}

fn handle_client(mut stream: UnixStream, state: &RwLock<LocalStatusSnapshot>) -> io::Result<()> {
    stream.set_read_timeout(Some(IO_TIMEOUT))?;
    stream.set_write_timeout(Some(IO_TIMEOUT))?;

    let mut line = String::new();
    {
        let mut reader = BufReader::new((&stream).take(MAX_REQUEST_BYTES as u64));
        let count = reader.read_line(&mut line)?;
        if count == 0 {
            return Ok(());
        }
    }

    let trimmed = line.trim();
    let event = match serde_json::from_str::<NativeCommand>(trimmed) {
        Ok(NativeCommand::Native {
            request: NativeRequest::ServiceStatus,
        }) => {
            let snapshot = state
                .read()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .clone();
            snapshot.to_event()
        }
        Ok(_) => NativeEvent::Failure {
            code: Some(ErrorCode::InvalidRequest),
            message: "Only service_status is supported on this local status socket".into(),
        },
        Err(_) => NativeEvent::Failure {
            code: Some(ErrorCode::InvalidRequest),
            message: "Invalid local status request".into(),
        },
    };

    write_event(&mut stream, &event)?;
    write_event(&mut stream, &NativeEvent::Done)?;
    stream.flush()
}

fn write_event(stream: &mut UnixStream, event: &NativeEvent) -> io::Result<()> {
    let mut bytes = serde_json::to_vec(event).map_err(io::Error::other)?;
    bytes.push(b'\n');
    stream.write_all(&bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader};

    fn query(socket_path: &Path, command: &NativeCommand) -> Vec<NativeEvent> {
        let mut stream = UnixStream::connect(socket_path).expect("connect status socket");
        let mut bytes = serde_json::to_vec(command).unwrap();
        bytes.push(b'\n');
        stream.write_all(&bytes).unwrap();
        stream.flush().unwrap();
        let reader = BufReader::new(stream);
        reader
            .lines()
            .map(|line| serde_json::from_str::<NativeEvent>(&line.unwrap()).unwrap())
            .collect()
    }

    #[test]
    fn worker_status_socket_reports_transitions_sets_private_mode_and_unlinks_on_drop() {
        let dir = tempfile::tempdir_in("/tmp").unwrap();
        let socket_path = dir.path().join(WORKER_SOCKET_NAME);
        let server =
            LocalStatusServer::start_worker(dir.path(), "tailscale://100.64.0.10".into()).unwrap();

        let mode = fs::symlink_metadata(&socket_path)
            .unwrap()
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o600);

        // Initial Connecting state.
        let request = NativeCommand::Native {
            request: NativeRequest::ServiceStatus,
        };
        let events = query(&socket_path, &request);
        assert_eq!(events.len(), 2);
        assert!(matches!(
            &events[0],
            NativeEvent::ServiceStatus {
                role: Some(ServiceRole::Worker),
                connection_state: Some(ServiceConnectionState::Connecting),
                target: Some(target),
                coordinator_id,
                node_name: None,
                ..
            } if target == "tailscale://100.64.0.10" && coordinator_id.is_empty()
        ));
        assert!(matches!(events[1], NativeEvent::Done));

        // Transition to Connected.
        server.set_worker_connected("coord-123".into(), "workstation".into());
        let events = query(&socket_path, &request);
        assert!(matches!(
            &events[0],
            NativeEvent::ServiceStatus {
                role: Some(ServiceRole::Worker),
                connection_state: Some(ServiceConnectionState::Connected),
                coordinator_id,
                node_name: Some(name),
                detail: None,
                ..
            } if coordinator_id == "coord-123" && name == "workstation"
        ));

        // Transition to Reconnecting preserves node_name and surfaces detail.
        server.set_worker_reconnecting("Coordinator closed the worker connection".into());
        let events = query(&socket_path, &request);
        assert!(matches!(
            &events[0],
            NativeEvent::ServiceStatus {
                role: Some(ServiceRole::Worker),
                connection_state: Some(ServiceConnectionState::Reconnecting),
                node_name: Some(name),
                detail: Some(detail),
                ..
            } if name == "workstation" && detail.contains("Coordinator closed")
        ));

        // Non-status native requests are rejected cleanly without ending the listener.
        let rejected = query(
            &socket_path,
            &NativeCommand::Native {
                request: NativeRequest::Identify,
            },
        );
        assert!(matches!(
            &rejected[0],
            NativeEvent::Failure {
                code: Some(ErrorCode::InvalidRequest),
                ..
            }
        ));

        // Refuses to clobber a live listener.
        assert!(
            LocalStatusServer::start_worker(dir.path(), "other".into()).is_err(),
            "must not replace an active local status socket"
        );

        drop(server);
        assert!(!socket_path.exists(), "socket must be unlinked on Drop");
    }

    #[test]
    fn standby_status_socket_reports_following_and_replaces_stale_socket() {
        let dir = tempfile::tempdir_in("/tmp").unwrap();
        let socket_path = dir.path().join(STANDBY_SOCKET_NAME);

        // Create a stale socket (bind then close without unlinking).
        let stale = UnixListener::bind(&socket_path).unwrap();
        drop(stale);
        assert!(socket_path.exists());

        let server = LocalStatusServer::start_standby(dir.path(), "coord-abc".into()).unwrap();
        let request = NativeCommand::Native {
            request: NativeRequest::ServiceStatus,
        };

        server.set_standby_following(42);
        let events = query(&socket_path, &request);
        assert!(matches!(
            &events[0],
            NativeEvent::ServiceStatus {
                role: Some(ServiceRole::Standby),
                connection_state: Some(ServiceConnectionState::Following),
                coordinator_id,
                applied_position: Some(42),
                detail: None,
                ..
            } if coordinator_id == "coord-abc"
        ));

        server.set_standby_unreachable("Authority timed out".into());
        let events = query(&socket_path, &request);
        assert!(matches!(
            &events[0],
            NativeEvent::ServiceStatus {
                role: Some(ServiceRole::Standby),
                connection_state: Some(ServiceConnectionState::AuthorityUnreachable),
                applied_position: Some(42),
                detail: Some(detail),
                ..
            } if detail == "Authority timed out"
        ));

        drop(server);
        assert!(!socket_path.exists());
    }

    #[test]
    fn refuses_to_overwrite_foreign_non_socket_file() {
        let dir = tempfile::tempdir_in("/tmp").unwrap();
        let socket_path = dir.path().join(WORKER_SOCKET_NAME);
        fs::write(&socket_path, "keep me").unwrap();
        assert!(LocalStatusServer::start_worker(dir.path(), "host".into()).is_err());
        assert_eq!(fs::read_to_string(&socket_path).unwrap(), "keep me");
    }

    #[test]
    fn drop_returns_promptly_even_if_socket_file_was_deleted_externally() {
        let dir = tempfile::tempdir_in("/tmp").unwrap();
        let socket_path = dir.path().join(WORKER_SOCKET_NAME);
        let server =
            LocalStatusServer::start_worker(dir.path(), "tailscale://100.64.0.10".into()).unwrap();
        fs::remove_file(&socket_path).unwrap();
        drop(server);
        assert!(!socket_path.exists());
    }
}
