//! Starting the local coordinator on demand and waiting for it.
//!
//! A command that finds no local coordinator starts `serve --local-only` detached
//! and waits for it to open `agent.sock`. The coordinator opens that socket only
//! after Pi has loaded and recovered its state, which has taken most of a
//! minute on a loaded Mac, so the wait is long. An interactive chat can leave
//! during the wait; the coordinator keeps starting either way.
//!
//! A coordinator takes `writer.lock` before anything else and holds it until it
//! and its Pi child exit. A command that finds the lock held waits for the
//! coordinator that holds it instead of starting a second one, and one whose
//! own start lost that lock to another start waits for the winner.

use std::{
    fs::{self, OpenOptions},
    io::ErrorKind,
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
    process::{ExitStatus, Stdio},
    time::{Duration, SystemTime},
};

use agent_cli::{serialized_spawn::SerializedTokioSpawn, service};
use anyhow::{Context, Result, anyhow};
use tokio::{
    net::UnixStream,
    process::{Child, Command},
    time::{Instant, sleep},
};

/// How long a command waits for a local coordinator to open its socket. A
/// healthy cold start under heavy load took 47 seconds.
pub(crate) const START_LIMIT: Duration = Duration::from_secs(120);
const POLL: Duration = Duration::from_millis(25);
/// How often a command that waits for another start checks that it lives.
const PROBE: Duration = Duration::from_secs(1);

/// Connects to the coordinator that owns `directory`. When none is running and
/// no start is in progress, starts the one that `command` builds, then waits up to
/// `limit` for a coordinator to open the socket.
pub(crate) async fn connect(
    directory: &Path,
    limit: Duration,
    command: impl FnOnce() -> Result<Command>,
) -> Result<UnixStream> {
    match service::connect(directory).await {
        Ok(stream) => return Ok(stream),
        Err(error)
            if matches!(
                error.kind(),
                ErrorKind::NotFound | ErrorKind::ConnectionRefused
            ) => {}
        Err(error) => return Err(error).context("Could not connect to the local coordinator"),
    }
    let files = Files::new(directory);
    let mut command = Some(command);
    let mut start = Start::Earlier { ours: None };
    if !files.lock_held()?
        && let Some(command) = command.take()
    {
        start = Start::Ours(files.spawn(command()?)?);
    }
    let deadline = Instant::now() + limit;
    let mut next_probe = Instant::now() + PROBE;
    loop {
        if let Ok(stream) = service::connect(directory).await {
            return Ok(stream);
        }
        match &mut start {
            Start::Ours(child) => {
                if let Some(status) = child.try_wait()? {
                    if let Ok(stream) = service::connect(directory).await {
                        return Ok(stream);
                    }
                    if !files.lock_held()? {
                        return Err(files.exited(status));
                    }
                    // Another start took the writer lock first; wait for it.
                    start = Start::Earlier { ours: Some(status) };
                }
            }
            Start::Earlier { ours } if Instant::now() >= next_probe => {
                next_probe = Instant::now() + PROBE;
                if !files.lock_held()? {
                    if let Ok(stream) = service::connect(directory).await {
                        return Ok(stream);
                    }
                    // The holder stopped without serving. Start once, so a
                    // backup that held the lock does not fail this command.
                    match command.take() {
                        Some(command) => start = Start::Ours(files.spawn(command()?)?),
                        None => return Err(files.ended(*ours)),
                    }
                }
            }
            Start::Earlier { .. } => {}
        }
        if Instant::now() >= deadline {
            return Err(files.timed_out(&mut start, limit));
        }
        sleep(POLL).await;
    }
}

enum Start {
    /// The coordinator this command started.
    Ours(Child),
    /// Another process held the writer lock, with this command's own start's
    /// exit status if it lost that lock.
    Earlier { ours: Option<ExitStatus> },
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Progress {
    /// The coordinator this command started is running.
    Starting,
    /// It exited, or the holder of the lock stopped.
    Ended,
    /// Whatever holds the lock may not be a coordinator.
    Unknown,
}

/// The state directory files that tell a start's progress.
struct Files {
    socket: PathBuf,
    lock: PathBuf,
    log: PathBuf,
    stages: PathBuf,
}

impl Files {
    fn new(directory: &Path) -> Self {
        Self {
            socket: directory.join("agent.sock"),
            lock: directory.join("writer.lock"),
            log: directory.join("coordinator.log"),
            stages: directory.join("diagnostics/startup.jsonl"),
        }
    }

    /// Starts `command` in its own session, so it outlives this command, with
    /// its stderr in coordinator.log.
    fn spawn(&self, mut command: Command) -> Result<Child> {
        let log = OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&self.log)
            .with_context(|| format!("Could not open {}", self.log.display()))?;
        command
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::from(log));
        unsafe {
            command.pre_exec(|| {
                if libc::setsid() == -1 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        command
            .spawn_serialized()
            .context("Could not start the local coordinator")
    }

    /// Whether a process holds writer.lock. A free lock is taken and
    /// released at once; `WriterLock::acquire` retries for longer than
    /// that, so a coordinator, backup or failover command that takes the
    /// lock meanwhile still gets it.
    fn lock_held(&self) -> Result<bool> {
        let file = match OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&self.lock)
        {
            Ok(file) => file,
            Err(error) if error.kind() == ErrorKind::NotFound => return Ok(false),
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("Could not read {}", self.lock.display()));
            }
        };
        match fs2::FileExt::try_lock_exclusive(&file) {
            Ok(()) => Ok(false),
            Err(error) if error.kind() == ErrorKind::WouldBlock => Ok(true),
            Err(error) => {
                Err(error).with_context(|| format!("Could not read {}", self.lock.display()))
            }
        }
    }

    fn exited(&self, status: ExitStatus) -> anyhow::Error {
        anyhow!(
            "The local coordinator exited with {status} before it opened {}. {} {}",
            self.socket.display(),
            self.log_note(Progress::Ended),
            self.stage_note()
        )
    }

    fn ended(&self, ours: Option<ExitStatus>) -> anyhow::Error {
        let ours = ours.map_or(String::new(), |status| {
            format!(" This command's own start exited with {status}.")
        });
        anyhow!(
            "The coordinator start that held {} stopped without opening {}.{ours} {} {}",
            self.lock.display(),
            self.socket.display(),
            self.log_note(Progress::Ended),
            self.stage_note()
        )
    }

    fn timed_out(&self, start: &mut Start, limit: Duration) -> anyhow::Error {
        let seconds = limit.as_secs_f64();
        let (progress, log) = match start {
            Start::Ours(child) => match (child.try_wait(), child.id()) {
                (Ok(Some(status)), _) => return self.exited(status),
                (_, Some(pid)) => (
                    format!(
                        "the local coordinator (process {pid}) is still running but has not opened {} after {seconds} seconds. It keeps starting in the background, and a later command connects to it without starting another.",
                        self.socket.display()
                    ),
                    Progress::Starting,
                ),
                (_, None) => (
                    format!(
                        "the local coordinator has not opened {} after {seconds} seconds.",
                        self.socket.display()
                    ),
                    Progress::Unknown,
                ),
            },
            Start::Earlier { ours } => (
                format!(
                    "a process holds {} but has not opened {} after {seconds} seconds, so this command started no second coordinator. An earlier coordinator start may still be in progress; a backup or failover command, or the Pi runtime of a coordinator that was killed, may also hold that lock.{}",
                    self.lock.display(),
                    self.socket.display(),
                    ours.map_or(String::new(), |status| format!(
                        " This command's own start found the lock taken and exited with {status}."
                    ))
                ),
                Progress::Unknown,
            ),
        };
        anyhow!(
            "Coordinator startup timed out: {progress} {} {}",
            self.log_note(log),
            self.stage_note()
        )
    }

    fn log_note(&self, progress: Progress) -> String {
        let log = self.log.display();
        match fs::metadata(&self.log) {
            Ok(metadata) if metadata.len() == 0 && progress == Progress::Starting => {
                format!(
                    "{log} is empty: the coordinator has reported no error and is still starting."
                )
            }
            Ok(metadata) if metadata.len() == 0 => format!("{log} is empty."),
            Ok(metadata) => format!("See {log} ({} bytes).", metadata.len()),
            Err(error) if error.kind() == ErrorKind::NotFound => format!("{log} does not exist."),
            Err(error) => format!("{log} is unreadable: {error}."),
        }
    }

    /// Pi records fixed stage names and numeric codes, never paths or
    /// payloads, so its last record is safe to repeat.
    fn stage_note(&self) -> String {
        let stages = self.stages.display();
        let text = match fs::read_to_string(&self.stages) {
            Ok(text) => text,
            Err(error) if error.kind() == ErrorKind::NotFound => {
                return format!(
                    "{stages} does not exist: no coordinator start in this state directory has reached storage_open."
                );
            }
            Err(error) => return format!("{stages} is unreadable: {error}."),
        };
        let last = text
            .lines()
            .rev()
            .find_map(|line| serde_json::from_str::<serde_json::Value>(line).ok());
        let Some(record) = last else {
            return format!("{stages} holds no startup stage.");
        };
        let field = |name| {
            record
                .get(name)
                .and_then(serde_json::Value::as_str)
                .unwrap_or("unknown")
        };
        let age = record
            .get("time_ms")
            .and_then(serde_json::Value::as_u64)
            .and_then(|time| {
                let now = SystemTime::now()
                    .duration_since(SystemTime::UNIX_EPOCH)
                    .ok()?;
                Some(now.as_millis().saturating_sub(u128::from(time)) / 1000)
            })
            .map_or(String::new(), |seconds| format!(" {seconds} seconds ago"));
        // The file outlives a start, so the age tells this start's record
        // from an earlier one's.
        format!(
            "The last startup stage in {stages} is {} {}{age}.",
            field("stage"),
            field("kind")
        )
    }
}

#[cfg(test)]
mod tests {
    use super::{Command, connect};
    use std::{
        fs::{self, File, OpenOptions},
        path::Path,
        sync::{Arc, Mutex},
        time::{Duration, Instant},
    };
    use tokio::{io::AsyncWriteExt, net::UnixListener, time::sleep};

    /// Serves one connection at agent.sock after `delay_ms`, like a coordinator
    /// whose Pi takes that long to load and recover.
    fn slow_coordinator(directory: &Path, delay_ms: u64) -> Command {
        let mut command = Command::new("node");
        command
            .args([
                "-e",
                "const net = require('node:net'); setTimeout(() => { const server = net.createServer((client) => { client.end('ready'); server.close(); }); server.listen(require('node:path').join(process.argv[1], 'agent.sock')); }, Number(process.argv[2]));",
            ])
            .arg(directory)
            .arg(delay_ms.to_string());
        command
    }

    /// The process ID a fixture wrote to `pid` in `directory`.
    async fn fixture_pid(directory: &Path) -> libc::pid_t {
        tokio::time::timeout(crate::TEST_HANG_LIMIT, async {
            loop {
                if let Some(pid) = fs::read_to_string(directory.join("pid"))
                    .ok()
                    .and_then(|pid| pid.trim().parse().ok())
                {
                    return pid;
                }
                sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap()
    }

    fn shell(script: &str, directory: &Path) -> Command {
        let mut command = Command::new("sh");
        command.args(["-c", script, "fixture"]).arg(directory);
        command
    }

    fn hold_writer_lock(directory: &Path) -> File {
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(directory.join("writer.lock"))
            .unwrap();
        fs2::FileExt::try_lock_exclusive(&lock).unwrap();
        lock
    }

    /// Binds agent.sock after `delay` and answers one client, as the
    /// coordinator that holds writer.lock would once it is ready.
    fn serve_later(directory: &Path, delay: Duration) -> tokio::task::JoinHandle<()> {
        let socket = directory.join("agent.sock");
        tokio::spawn(async move {
            sleep(delay).await;
            let listener = UnixListener::bind(socket).unwrap();
            let (mut client, _) = listener.accept().await.unwrap();
            // The waiting command may close before reading.
            let _ = client.write_all(b"ready").await;
        })
    }

    #[test]
    fn a_lock_probe_never_fails_a_coordinator_that_takes_the_lock() {
        let directory = tempfile::tempdir().unwrap();
        // Holds the free lock far longer than a probe's instant, and well
        // inside the grace that WriterLock::acquire allows.
        let probe = hold_writer_lock(directory.path());
        let release = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(20));
            drop(probe);
        });
        let taken = agent_cli::runtime::WriterLock::acquire(directory.path());
        release.join().unwrap();
        assert!(taken.is_ok(), "{:?}", taken.err());
        // A lock that stays held still refuses a second owner.
        let refused = agent_cli::runtime::WriterLock::acquire(directory.path())
            .err()
            .unwrap()
            .to_string();
        assert_eq!(refused, "Another agent process owns this state directory");
    }

    #[tokio::test]
    async fn a_start_slower_than_the_old_five_second_limit_connects() {
        let directory = tempfile::tempdir().unwrap();
        let started = Instant::now();
        let stream = connect(directory.path(), Duration::from_secs(60), || {
            Ok(slow_coordinator(directory.path(), 6_000))
        })
        .await
        .unwrap();
        let waited = started.elapsed();
        assert!(waited > Duration::from_secs(5), "{waited:?}");
        println!("connected after {waited:?}");
        drop(stream);
    }

    #[tokio::test]
    async fn a_coordinator_that_exits_while_starting_reports_its_status_and_log() {
        let directory = tempfile::tempdir().unwrap();
        let error = connect(directory.path(), Duration::from_secs(60), || {
            Ok(shell(
                "echo 'fixture coordinator could not start' >&2; exit 3",
                directory.path(),
            ))
        })
        .await
        .unwrap_err()
        .to_string();
        println!("{error}");
        let log = directory.path().join("coordinator.log");
        assert!(error.contains("exited with exit status: 3"), "{error}");
        assert!(
            error.contains(&format!("See {} (", log.display())),
            "{error}"
        );
        assert!(
            error.contains(
                &directory
                    .path()
                    .join("diagnostics/startup.jsonl")
                    .display()
                    .to_string()
            ),
            "{error}"
        );
        assert_eq!(
            fs::read_to_string(log).unwrap(),
            "fixture coordinator could not start\n"
        );
    }

    #[tokio::test]
    async fn a_start_that_never_binds_reports_that_it_is_still_running() {
        let directory = tempfile::tempdir().unwrap();
        let started = Instant::now();
        let error = connect(directory.path(), Duration::from_millis(500), || {
            Ok(shell(
                "echo $$ > \"$1/pid\"; exec sleep 60",
                directory.path(),
            ))
        })
        .await
        .unwrap_err()
        .to_string();
        assert!(started.elapsed() < Duration::from_secs(30));
        println!("{error}");
        let pid = fixture_pid(directory.path()).await;
        // Only the fixture this test started is signalled.
        assert_eq!(unsafe { libc::kill(pid, libc::SIGTERM) }, 0);
        let log = directory.path().join("coordinator.log");
        let stages = directory.path().join("diagnostics/startup.jsonl");
        assert!(
            error.starts_with("Coordinator startup timed out"),
            "{error}"
        );
        assert!(
            error.contains(&format!("(process {pid}) is still running")),
            "{error}"
        );
        assert!(
            error.contains(&format!(
                "{} is empty: the coordinator has reported no error and is still starting.",
                log.display()
            )),
            "{error}"
        );
        assert!(
            error.contains(&format!(
                "{} does not exist: no coordinator start",
                stages.display()
            )),
            "{error}"
        );
    }

    #[tokio::test]
    async fn the_last_startup_stage_is_reported_when_pi_recorded_one() {
        let directory = tempfile::tempdir().unwrap();
        fs::create_dir(directory.path().join("diagnostics")).unwrap();
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis();
        fs::write(
            directory.path().join("diagnostics/startup.jsonl"),
            format!(
                "{{\"version\":1,\"time_ms\":{now},\"stage\":\"storage_open\",\"kind\":\"begin\"}}\n"
            ),
        )
        .unwrap();
        let error = connect(directory.path(), Duration::from_millis(200), || {
            Ok(shell(
                "echo $$ > \"$1/pid\"; exec sleep 60",
                directory.path(),
            ))
        })
        .await
        .unwrap_err()
        .to_string();
        let pid = fixture_pid(directory.path()).await;
        assert_eq!(unsafe { libc::kill(pid, libc::SIGTERM) }, 0);
        assert!(error.contains("is storage_open begin "), "{error}");
        assert!(error.ends_with(" seconds ago."), "{error}");
    }

    #[tokio::test]
    async fn a_start_in_progress_is_awaited_without_starting_another() {
        let directory = tempfile::tempdir().unwrap();
        let _lock = hold_writer_lock(directory.path());
        let server = serve_later(directory.path(), Duration::from_millis(300));
        connect(directory.path(), Duration::from_secs(60), || {
            panic!("A second coordinator was started beside a start in progress")
        })
        .await
        .unwrap();
        server.await.unwrap();
        assert!(!directory.path().join("coordinator.log").exists());
    }

    #[tokio::test]
    async fn a_start_in_progress_that_never_binds_is_reported_not_hidden() {
        let directory = tempfile::tempdir().unwrap();
        let _lock = hold_writer_lock(directory.path());
        let error = connect(directory.path(), Duration::from_millis(300), || {
            panic!("A second coordinator was started beside a start in progress")
        })
        .await
        .unwrap_err()
        .to_string();
        println!("{error}");
        assert!(
            error.contains(&format!(
                "a process holds {} but has not opened {}",
                directory.path().join("writer.lock").display(),
                directory.path().join("agent.sock").display()
            )),
            "{error}"
        );
        assert!(error.contains("started no second coordinator"), "{error}");
    }

    #[tokio::test]
    async fn a_start_that_loses_the_writer_lock_waits_for_the_winner() {
        let directory = tempfile::tempdir().unwrap();
        let winner = Arc::new(Mutex::new(None));
        let held = winner.clone();
        let server = serve_later(directory.path(), Duration::from_millis(500));
        // The other start takes the lock between this command's check and
        // its own start, which then exits as the real one would.
        connect(directory.path(), Duration::from_secs(60), || {
            *held.lock().unwrap() = Some(hold_writer_lock(directory.path()));
            Ok(shell(
                "echo 'Error: Another agent process owns this state directory' >&2; exit 1",
                directory.path(),
            ))
        })
        .await
        .unwrap();
        server.await.unwrap();
        assert!(winner.lock().unwrap().is_some());
    }
}
