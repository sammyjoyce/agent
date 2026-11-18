//! Kernel evidence of whether anything a coordinator started is still alive.
//!
//! A coordinator holds a shared lock on `effects.lock` through a descriptor
//! that every process it starts inherits, whichever code starts it. Each
//! effect task of the coordinator holds the same share. The kernel ends the
//! share only when the last holder closes the file. An exclusive lock therefore
//! proves that none is left, which a recorded process id cannot, because an id
//! can be reused.
//!
//! A process can close the descriptors it inherited. So the coordinator also
//! records each process group that an effect leads, and a recorded group that
//! is still alive refuses the proof too. Only a process that both left its
//! group and closed the file is outside this evidence.

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
    _lock: File,
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
        // Inheritance is the default and not a step of each spawn, so a
        // process started by code that knows nothing of this lock holds it too.
        if unsafe { libc::fcntl(lock.as_raw_fd(), libc::F_SETFD, 0) } == -1 {
            return Err(io::Error::last_os_error())
                .context("Could not let child processes inherit effects.lock");
        }
        for (group, _) in recorded(&records) {
            if !group_alive(group) {
                let _ = fs::remove_file(records.join(group.to_string()));
            }
        }
        let scope = Arc::new(Scope {
            _lock: lock,
            records,
        });
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

/// A share of `effects.lock` for work that runs inside the coordinator's
/// process. `None` in a process that runs no coordinator.
pub(crate) struct EffectShare(#[allow(dead_code)] Arc<Scope>);

impl EffectShare {
    pub(crate) fn hold() -> Option<Self> {
        SCOPE.lock().ok()?.clone().map(Self)
    }
}

/// The record of a process group that an effect's child leads, with the time
/// its leader started, so a release can stop that group and no other. Keep it
/// until the child is reaped: it then removes the record.
pub(crate) struct EffectGroup {
    record: Option<PathBuf>,
}

impl EffectGroup {
    /// A record that cannot be written loses the name and not the proof: the
    /// child still holds the lock.
    pub(crate) fn led_by(child: Option<u32>) -> Self {
        let record = EffectShare::hold().zip(child).and_then(|(share, group)| {
            let leader = libc::pid_t::try_from(group).ok()?;
            let started = process_started(leader).map_or(String::new(), |time| time.to_string());
            let path = share.0.records.join(group.to_string());
            fs::write(&path, started).ok().map(|()| path)
        });
        Self { record }
    }
}

impl Drop for EffectGroup {
    fn drop(&mut self) {
        if let Some(record) = self.record.take() {
            let _ = fs::remove_file(record);
        }
    }
}

/// Proof that no effect of the state directory is alive, as far as the kernel
/// can tell. It holds `effects.lock` exclusively, so keep it until the
/// evidence is posted.
pub(crate) struct EffectsStopped(#[allow(dead_code)] File);

/// An effect of the state directory is alive, or cannot be shown to have ended.
#[derive(Debug)]
pub struct SurvivingEffects {
    lock: PathBuf,
    lock_still_held: bool,
    killed_but_alive: Vec<libc::pid_t>,
    alive_with_other_leader: Vec<libc::pid_t>,
}

impl fmt::Display for SurvivingEffects {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("This coordinator's local effects are not shown to have ended.")?;
        for group in &self.killed_but_alive {
            write!(
                f,
                " The process group {group} was sent SIGKILL and has not ended."
            )?;
        }
        for group in &self.alive_with_other_leader {
            write!(
                f,
                " The process group {group} is alive and was not signalled, because the process this coordinator recorded no longer leads it."
            )?;
        }
        if self.lock_still_held {
            write!(f, " A process still holds {}.", self.lock.display())?;
            if self.killed_but_alive.is_empty() && self.alive_with_other_leader.is_empty() {
                write!(
                    f,
                    " No record names it: it left the process group it was started in, or it never led one. `lsof {}` lists it.",
                    self.lock.display()
                )?;
            }
        }
        f.write_str(
            " Stop it and run `beep-boop failover release` again, or promote the standby on your own statement with `beep-boop failover promote --old-owner-stopped \"<statement>\"`.",
        )
    }
}

impl std::error::Error for SurvivingEffects {}

/// Under the writer lock, which proves that no supervisor and no Pi child is
/// alive: stops every recorded process group whose leader is still the
/// recorded process, and returns only once no recorded group is alive and the
/// kernel says that nothing holds `effects.lock`.
pub(crate) fn stop_survivors(_lock: &WriterLock, state: &Path) -> Result<EffectsStopped> {
    let lock = open(state).context("Could not open effects.lock")?;
    let records = state.join(RECORDS);
    let mut killed = Vec::new();
    let mut unverified = Vec::new();
    for (group, recorded_start) in recorded(&records) {
        if !group_alive(group) {
            continue;
        }
        // Only its recorded leader names a group. Once that process is gone,
        // the id may belong to a group that another program started.
        if recorded_start.is_some() && recorded_start == process_started(group) {
            unsafe {
                libc::kill(-group, libc::SIGKILL);
            }
            killed.push(group);
        } else {
            unverified.push(group);
        }
    }
    let deadline = Instant::now() + STOP_LIMIT;
    let held = loop {
        killed.retain(|group| group_alive(*group));
        let held = fs2::FileExt::try_lock_exclusive(&lock).is_err();
        if (!held && killed.is_empty()) || Instant::now() >= deadline {
            break held;
        }
        thread::sleep(Duration::from_millis(25));
    };
    unverified.retain(|group| group_alive(*group));
    if held || !killed.is_empty() || !unverified.is_empty() {
        return Err(SurvivingEffects {
            lock: state.join(LOCK_FILE),
            lock_still_held: held,
            killed_but_alive: killed,
            alive_with_other_leader: unverified,
        }
        .into());
    }
    for (group, _) in recorded(&records) {
        let _ = fs::remove_file(records.join(group.to_string()));
    }
    Ok(EffectsStopped(lock))
}

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

fn group_alive(group: libc::pid_t) -> bool {
    let sent = unsafe { libc::kill(-group, 0) };
    sent == 0 || io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
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
