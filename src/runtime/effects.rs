//! Kernel evidence of whether a local effect process of a state directory is alive.
//!
//! A coordinator holds a shared lock on `effects.lock`, and every effect
//! process it starts inherits that open file. The kernel ends the share only
//! when the last process that holds the file exits. An exclusive lock therefore
//! proves that none is left, which a recorded process id cannot, because an id
//! can be reused.

use std::{
    fmt,
    fs::{self, DirBuilder, File, OpenOptions},
    io,
    os::{
        fd::AsRawFd,
        unix::fs::{DirBuilderExt, OpenOptionsExt},
    },
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    thread,
    time::{Duration, Instant},
};

use anyhow::{Context, Result};

use crate::runtime::WriterLock;

const LOCK_FILE: &str = "effects.lock";
const RECORDS: &str = "effects";
const STOP_LIMIT: Duration = Duration::from_secs(5);

struct Scope {
    lock: File,
    records: PathBuf,
}

/// The coordinator this process runs. A worker daemon never sets it, so its
/// effects inherit nothing and record nothing.
static SCOPE: Mutex<Option<Arc<Scope>>> = Mutex::new(None);

fn open(state: &Path) -> io::Result<File> {
    OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(state.join(LOCK_FILE))
}

/// A coordinator's share of `effects.lock`, held while its claim lives.
pub(crate) struct EffectsLock(Arc<Scope>);

impl EffectsLock {
    /// A share never waits for another share, so an effect process that
    /// outlived an earlier coordinator does not stop this one from starting.
    pub(crate) fn share(state: &Path) -> Result<Self> {
        let records = state.join(RECORDS);
        DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&records)
            .with_context(|| format!("Could not create {}", records.display()))?;
        let lock = open(state).context("Could not open effects.lock")?;
        fs2::FileExt::try_lock_shared(&lock).context("Could not share effects.lock")?;
        for (group, _) in recorded(&records) {
            if !group_alive(group) {
                let _ = fs::remove_file(records.join(group.to_string()));
            }
        }
        let scope = Arc::new(Scope { lock, records });
        if let Ok(mut current) = SCOPE.lock() {
            *current = Some(scope.clone());
        }
        Ok(Self(scope))
    }
}

impl Drop for EffectsLock {
    fn drop(&mut self) {
        if let Ok(mut current) = SCOPE.lock()
            && current
                .as_ref()
                .is_some_and(|scope| Arc::ptr_eq(scope, &self.0))
        {
            *current = None;
        }
    }
}

/// One effect process of the coordinator this process runs. Made before the
/// spawn, so the child inherits the coordinator's share of `effects.lock`.
/// Keep it until the child is reaped: it then removes the group's record.
pub(crate) struct EffectProcess {
    scope: Option<Arc<Scope>>,
    record: Option<PathBuf>,
}

impl EffectProcess {
    pub(crate) fn of(command: &mut tokio::process::Command) -> Self {
        let scope = SCOPE.lock().ok().and_then(|current| current.clone());
        if let Some(scope) = &scope {
            let lock = scope.lock.as_raw_fd();
            // `scope` keeps this descriptor open until after the spawn.
            unsafe {
                command.pre_exec(move || {
                    if libc::fcntl(lock, libc::F_SETFD, 0) == -1 {
                        return Err(io::Error::last_os_error());
                    }
                    Ok(())
                });
            }
        }
        Self {
            scope,
            record: None,
        }
    }

    /// Records the process group the child leads, with the time its leader
    /// started, so a release can stop that group and no other. A record that
    /// cannot be written loses the name and not the proof: the child still
    /// holds the lock.
    pub(crate) fn leads(&mut self, group: Option<u32>) {
        let (Some(scope), Some(group)) = (&self.scope, group) else {
            return;
        };
        let Ok(leader) = libc::pid_t::try_from(group) else {
            return;
        };
        let started = process_started(leader).map_or(String::new(), |time| time.to_string());
        let path = scope.records.join(group.to_string());
        if fs::write(&path, started).is_ok() {
            self.record = Some(path);
        }
    }
}

impl Drop for EffectProcess {
    fn drop(&mut self) {
        if let Some(record) = self.record.take() {
            let _ = fs::remove_file(record);
        }
    }
}

/// Proof that no effect process of the state directory is alive. It holds
/// `effects.lock` exclusively, so keep it until the evidence is posted.
pub(crate) struct EffectsStopped(#[allow(dead_code)] File);

/// An effect process of the state directory is alive and could not be stopped.
#[derive(Debug)]
pub struct SurvivingEffects {
    lock: PathBuf,
    /// Recorded groups that were sent SIGKILL and are still alive.
    killed: Vec<libc::pid_t>,
    /// Recorded groups whose leader is not the recorded process.
    unverified: Vec<libc::pid_t>,
}

impl fmt::Display for SurvivingEffects {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "A process that this coordinator started is still alive: it holds {}.",
            self.lock.display()
        )?;
        for group in &self.killed {
            write!(
                f,
                " The process group {group} was sent SIGKILL and has not ended."
            )?;
        }
        for group in &self.unverified {
            write!(
                f,
                " The process group {group} was not signalled, because its leader is not the process this coordinator recorded."
            )?;
        }
        if self.killed.is_empty() && self.unverified.is_empty() {
            write!(
                f,
                " It left the process group it was started in, so no record names it. `lsof {}` lists it.",
                self.lock.display()
            )?;
        }
        f.write_str(
            " Stop it and run `beep-boop failover release` again, or promote the standby on your own statement with `beep-boop failover promote --old-owner-stopped \"<statement>\"`.",
        )
    }
}

impl std::error::Error for SurvivingEffects {}

/// Under the writer lock, which proves that no supervisor and no Pi child is
/// alive: stops every recorded process group that is still alive, and returns
/// only once the kernel says that no effect process is left.
pub(crate) fn stop_survivors(_lock: &WriterLock, state: &Path) -> Result<EffectsStopped> {
    let lock = open(state).context("Could not open effects.lock")?;
    let records = state.join(RECORDS);
    let mut killed = Vec::new();
    let mut unverified = Vec::new();
    if fs2::FileExt::try_lock_exclusive(&lock).is_err() {
        for (group, recorded_start) in recorded(&records) {
            if !group_alive(group) {
                continue;
            }
            let leader = process_started(group);
            // A group outlives its leader, and its id is not given to a new
            // process while a member is alive.
            let same = match (recorded_start, leader) {
                (Some(recorded_start), Some(leader)) => recorded_start == leader,
                (Some(_), None) => !process_alive(group),
                (None, _) => false,
            };
            if same {
                unsafe {
                    libc::kill(-group, libc::SIGKILL);
                }
                killed.push(group);
            } else {
                unverified.push(group);
            }
        }
        let deadline = Instant::now() + STOP_LIMIT;
        while fs2::FileExt::try_lock_exclusive(&lock).is_err() {
            if Instant::now() >= deadline {
                killed.retain(|group| group_alive(*group));
                return Err(SurvivingEffects {
                    lock: state.join(LOCK_FILE),
                    killed,
                    unverified,
                }
                .into());
            }
            thread::sleep(Duration::from_millis(25));
        }
    }
    for (group, _) in recorded(&records) {
        let _ = fs::remove_file(records.join(group.to_string()));
    }
    Ok(EffectsStopped(lock))
}

/// Each recorded process group with the time its leader started.
fn recorded(records: &Path) -> Vec<(libc::pid_t, Option<u64>)> {
    let Ok(entries) = fs::read_dir(records) else {
        return Vec::new();
    };
    entries
        .flatten()
        .filter_map(|entry| {
            let group = entry.file_name().to_str()?.parse::<libc::pid_t>().ok()?;
            let started = fs::read_to_string(entry.path()).ok()?.trim().parse().ok();
            (group > 1).then_some((group, started))
        })
        .collect()
}

fn signalled(target: libc::pid_t) -> bool {
    let sent = unsafe { libc::kill(target, 0) };
    sent == 0 || io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

fn group_alive(group: libc::pid_t) -> bool {
    signalled(-group)
}

fn process_alive(process: libc::pid_t) -> bool {
    signalled(process)
}

/// When the process started, in units that only compare for equality.
#[cfg(target_os = "macos")]
fn process_started(process: libc::pid_t) -> Option<u64> {
    let mut information: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = libc::c_int::try_from(size_of::<libc::proc_bsdinfo>()).ok()?;
    let read = unsafe {
        libc::proc_pidinfo(
            process,
            libc::PROC_PIDTBSDINFO,
            0,
            (&raw mut information).cast(),
            size,
        )
    };
    (read == size).then(|| information.pbi_start_tvsec * 1_000_000 + information.pbi_start_tvusec)
}

#[cfg(not(target_os = "macos"))]
fn process_started(process: libc::pid_t) -> Option<u64> {
    let stat = fs::read_to_string(format!("/proc/{process}/stat")).ok()?;
    // The command name is in parentheses and may hold spaces. The start time
    // is the twentieth field after it.
    stat.rsplit_once(')')?
        .1
        .split_whitespace()
        .nth(19)?
        .parse()
        .ok()
}
