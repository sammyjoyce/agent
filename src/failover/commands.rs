//! The `beep-boop failover` commands. Each one reads the authority's record
//! and the state directory and applies only the difference, so a rerun after
//! a crash at any step ends in the same state.

use std::{
    fmt, fs,
    path::{Path, PathBuf},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result, bail, ensure};
use uuid::Uuid;

use super::{
    AuthorityCommand, AuthorityRecord, AuthorityRefusal, AuthorityReply, AuthorityState,
    AuthorityUnreachable, CheckpointRecord, FailoverConfig, FailoverOperator, FailoverSession,
    HolderId, LogPosition, OperatorReport, OperatorRequest, OwnerEpoch, REPLICATED_FILE_ROOTS,
    ReleaseEvidence, StopEvidence,
};
use crate::{
    backup,
    coordinator_id::CoordinatorId,
    runtime::{WriterLock, effects},
};

pub use super::receipts::{
    Checkpointed, Enrolled, Followed, Joined, Promoted, Released, Status, Uploaded,
};

const EVIDENCE_POLL: Duration = Duration::from_millis(500);

/// The authority refused a command. The message names the current owner and epoch.
#[derive(Debug)]
pub struct Refused {
    action: &'static str,
    reason: AuthorityRefusal,
    state: Option<AuthorityState>,
}

impl fmt::Display for Refused {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "The failover authority refused {} ({:?}): ",
            self.action, self.reason
        )?;
        match &self.state {
            Some(state) => state.fmt(f),
            None => f.write_str("the authority has no record of this coordinator"),
        }
    }
}

impl std::error::Error for Refused {}

/// One coordinator's authority, as this host's operator script reaches it.
struct Authority {
    operator: FailoverOperator,
    session: FailoverSession,
}

impl Authority {
    fn open(script: &Path, config: &FailoverConfig, coordinator_id: CoordinatorId) -> Result<Self> {
        Ok(Self {
            operator: FailoverOperator::locate(script)?,
            session: FailoverSession {
                url: config.url.clone(),
                token_file: config.token_file.clone(),
                coordinator_id,
                holder: config.holder,
                epoch: None,
            },
        })
    }

    fn run(&self, request: &OperatorRequest) -> Result<OperatorReport> {
        self.operator.run(&self.session, request)
    }

    /// Runs a request that writes to the state directory `lock` guards.
    fn write(&self, lock: &WriterLock, request: &OperatorRequest) -> Result<OperatorReport> {
        self.operator.run_holding(lock, &self.session, request)
    }

    fn status(
        &self,
        state: Option<&Path>,
    ) -> Result<(Option<AuthorityRecord>, Option<LogPosition>)> {
        match self.run(&OperatorRequest::Status {
            state: state.map(Path::to_owned),
        })? {
            OperatorReport::Status { record, applied } => Ok((record, applied)),
            other => Err(unexpected("status", &other)),
        }
    }

    fn enrolled(&self) -> Result<AuthorityRecord> {
        self.status(None)?.0.with_context(|| {
            format!(
                "The authority has no record of coordinator {}. Run `beep-boop failover enroll` on its owner first",
                self.session.coordinator_id
            )
        })
    }

    /// Runs one command. A refusal is an error that names the owner and epoch.
    fn command(&self, action: &'static str, command: AuthorityCommand) -> Result<AuthorityState> {
        match self.run(&OperatorRequest::Authority { command })? {
            OperatorReport::Reply {
                reply: AuthorityReply::Accepted { state },
            } => Ok(state),
            OperatorReport::Reply {
                reply: AuthorityReply::Refused { reason, state },
            } => Err(Refused {
                action,
                reason,
                state,
            }
            .into()),
            other => Err(unexpected("authority", &other)),
        }
    }
}

fn unexpected(request: &str, report: &OperatorReport) -> anyhow::Error {
    anyhow::anyhow!("The failover operator answered {request} with another report: {report:?}")
}

fn holder(config: &FailoverConfig) -> Result<HolderId> {
    config.holder.context(
        "This host's [failover] section has no holder, so it can read the owner record and nothing else",
    )
}

/// Takes the writer lock of an existing state directory and reads its identity.
fn lock_state(state: &Path) -> Result<(WriterLock, CoordinatorId)> {
    ensure!(
        state.is_dir(),
        "The state directory {} does not exist",
        state.display()
    );
    let lock = WriterLock::acquire(state)?;
    let coordinator_id = CoordinatorId::read(state)?.with_context(|| {
        format!(
            "{} has no coordinator-id. A coordinator writes it at its first start, and `beep-boop failover join` writes it into a standby",
            state.display()
        )
    })?;
    Ok((lock, coordinator_id))
}

/// A directory beside `directory` for one command's checkpoint archive. It is
/// removed when the command ends.
struct Scratch(PathBuf);

impl Scratch {
    fn beside(directory: &Path, purpose: &str) -> Result<Self> {
        let (parent, name) = parent_and_name(directory)?;
        Ok(Self(
            parent.join(format!(".{name}.{purpose}-{}", Uuid::new_v4())),
        ))
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn parent_and_name(directory: &Path) -> Result<(PathBuf, String)> {
    let absolute = std::path::absolute(directory)?;
    let parent = absolute
        .parent()
        .with_context(|| format!("{} has no parent directory", absolute.display()))?;
    let name = absolute
        .file_name()
        .and_then(|name| name.to_str())
        .with_context(|| format!("{} has no plain name", absolute.display()))?;
    Ok((parent.to_owned(), name.to_owned()))
}

/// Prints what the authority holds. Takes no lock and writes nothing.
pub fn status(
    state: &Path,
    coordinator_id: Option<CoordinatorId>,
    script: &Path,
    config: &FailoverConfig,
) -> Result<Status> {
    let present = state.is_dir();
    let local = if present {
        CoordinatorId::read(state)?
    } else {
        None
    };
    let coordinator_id = match (coordinator_id, local) {
        (Some(named), Some(local)) => {
            ensure!(
                named == local,
                "{} belongs to coordinator {local}, not {named}",
                state.display()
            );
            named
        }
        (Some(id), None) | (None, Some(id)) => id,
        (None, None) => bail!(
            "{} has no coordinator-id. Name the coordinator with --coordinator-id",
            state.display()
        ),
    };
    let (record, applied) =
        Authority::open(script, config, coordinator_id)?.status(present.then_some(state))?;
    Ok(Status {
        coordinator_id,
        record,
        state_dir: std::path::absolute(state)?,
        applied,
    })
}

/// Archives the locked state directory and stores the archive as a checkpoint
/// at the position its database holds.
fn store_checkpoint(
    authority: &Authority,
    lock: &WriterLock,
    state: &Path,
    script: &Path,
    part_bytes: Option<u64>,
) -> Result<(CheckpointRecord, Uploaded)> {
    let scratch = Scratch::beside(state, "checkpoint")?;
    let created = backup::create_locked(lock, state, &scratch.0, script)?;
    let left_out: Vec<&str> = created
        .not_included
        .iter()
        .map(String::as_str)
        .filter(|path| {
            REPLICATED_FILE_ROOTS.iter().any(|root| {
                path.strip_prefix(root)
                    .is_some_and(|rest| rest.starts_with('/'))
            })
        })
        .collect();
    ensure!(
        left_out.is_empty(),
        "A checkpoint would leave out {}: a backup does not carry them, and they lie in a replicated tree, so a standby that joins would lack them. Move them out of {}",
        left_out.join(", "),
        state.display()
    );
    match authority.run(&OperatorRequest::StoreCheckpoint {
        archive: scratch.0.clone(),
        part_bytes,
    })? {
        OperatorReport::Stored {
            checkpoint,
            files,
            bytes,
        } => Ok((
            checkpoint,
            Uploaded {
                files,
                bytes,
                not_included: created.not_included,
            },
        )),
        other => Err(unexpected("store_checkpoint", &other)),
    }
}

/// Makes a stopped coordinator's state directory the first owner of a
/// replicated coordinator. The position is stamped before the checkpoint is
/// taken, so the checkpoint carries it and a rerun never has to guess whether
/// an unstamped directory is the enrolled one.
pub fn enroll(
    state: &Path,
    script: &Path,
    config: &FailoverConfig,
    part_bytes: Option<u64>,
) -> Result<Enrolled> {
    let holder = holder(config)?;
    let (lock, coordinator_id) = lock_state(state)?;
    let authority = Authority::open(script, config, coordinator_id)?;
    if let (Some(record), applied) = authority.status(Some(state))? {
        let AuthorityState::Active {
            epoch,
            holder: owner,
            ..
        } = record.state
        else {
            return Err(enrolled_already(record.state));
        };
        if owner != holder {
            return Err(enrolled_already(record.state));
        }
        ensure!(
            applied.is_some(),
            "Holder {} already enrolled coordinator {coordinator_id} from another state directory: {} holds no log position. Run `beep-boop failover join --replace` to rebuild it from the checkpoint",
            holder.get(),
            state.display()
        );
        return Ok(Enrolled {
            coordinator_id,
            holder,
            epoch,
            checkpoint: record.checkpoint,
            uploaded: None,
        });
    }
    let start = LogPosition::new(0)?;
    match authority.write(
        &lock,
        &OperatorRequest::Stamp {
            state: state.to_owned(),
            position: start,
        },
    )? {
        OperatorReport::Stamped => {}
        other => return Err(unexpected("stamp", &other)),
    }
    let (checkpoint, uploaded) = store_checkpoint(&authority, &lock, state, script, part_bytes)?;
    ensure!(
        checkpoint.through == start,
        "The checkpoint of a directory that enrolls must be at position 0, not {}",
        checkpoint.through.get()
    );
    let enrolled = authority.command(
        "this enrollment",
        AuthorityCommand::Enroll {
            holder,
            checkpoint: checkpoint.clone(),
        },
    )?;
    let AuthorityState::Active { epoch, .. } = enrolled else {
        return Err(enrolled_already(enrolled));
    };
    Ok(Enrolled {
        coordinator_id,
        holder,
        epoch,
        checkpoint,
        uploaded: Some(uploaded),
    })
}

fn enrolled_already(state: AuthorityState) -> anyhow::Error {
    Refused {
        action: "this enrollment",
        reason: AuthorityRefusal::Enrolled,
        state: Some(state),
    }
    .into()
}

/// Replaces the authority's checkpoint with the stopped owner's state
/// directory, which drops the log entries the checkpoint covers.
pub fn checkpoint(
    state: &Path,
    script: &Path,
    config: &FailoverConfig,
    part_bytes: Option<u64>,
) -> Result<Checkpointed> {
    let holder = holder(config)?;
    let (lock, coordinator_id) = lock_state(state)?;
    let authority = Authority::open(script, config, coordinator_id)?;
    let claimed = authority.command("this checkpoint", AuthorityCommand::Claim { holder })?;
    let AuthorityState::Active { epoch, head, .. } = claimed else {
        bail!("The authority accepted a claim and reported no owner");
    };
    let (checkpoint, uploaded) = store_checkpoint(&authority, &lock, state, script, part_bytes)?;
    authority.command(
        "this checkpoint",
        AuthorityCommand::Checkpoint {
            holder,
            epoch,
            record: checkpoint.clone(),
        },
    )?;
    Ok(Checkpointed {
        coordinator_id,
        epoch,
        checkpoint,
        head,
        uploaded,
    })
}

/// Builds a standby's state directory from the authority's checkpoint. The
/// checkpoint is downloaded and checked beside the target, then published
/// whole, so a refused or interrupted join leaves no target.
pub fn join(
    target: &Path,
    coordinator_id: CoordinatorId,
    replace: bool,
    script: &Path,
    config: &FailoverConfig,
) -> Result<Joined> {
    holder(config)?;
    let authority = Authority::open(script, config, coordinator_id)?;
    let (parent, name) = parent_and_name(target)?;
    ensure!(
        parent.is_dir(),
        "{} does not exist, so a standby cannot be built in it",
        parent.display()
    );
    let occupied = match fs::read_dir(target) {
        Ok(mut entries) => entries.next().is_some(),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
        Err(error) => {
            return Err(error).with_context(|| format!("Could not inspect {}", target.display()));
        }
    };
    ensure!(
        replace || !occupied,
        "{} is not empty. `beep-boop failover join` builds a standby in an absent or empty directory, and `failover join --replace` first renames the directory that is there",
        target.display()
    );
    // Held until the join ends, so nothing starts in the directory it set aside.
    let mut set_aside = None;
    if occupied {
        let lock = WriterLock::acquire(target)?;
        let renamed = parent.join(format!(
            "{name}.replaced-{}",
            SystemTime::now().duration_since(UNIX_EPOCH)?.as_millis()
        ));
        ensure!(
            !renamed.exists(),
            "{} already exists, so the present directory cannot be renamed to it",
            renamed.display()
        );
        fs::rename(target, &renamed)
            .with_context(|| format!("Could not rename {}", target.display()))?;
        fs::File::open(&parent)?.sync_all()?;
        set_aside = Some((lock, renamed));
    }
    let replaced = set_aside.as_ref().map(|(_, renamed)| renamed.clone());
    let (checkpoint, files, bytes, restored) =
        restore_checkpoint(&authority, target, coordinator_id, script).with_context(|| {
            match &replaced {
                Some(renamed) => format!(
                    "No standby was built in {}. The directory that was there is now {}",
                    target.display(),
                    renamed.display()
                ),
                None => format!("No standby was built in {}", target.display()),
            }
        })?;
    Ok(Joined {
        coordinator_id,
        state_dir: restored,
        through: checkpoint.through,
        files,
        bytes,
        replaced,
    })
}

/// Downloads the current checkpoint beside `target`, then restores it there.
fn restore_checkpoint(
    authority: &Authority,
    target: &Path,
    coordinator_id: CoordinatorId,
    script: &Path,
) -> Result<(CheckpointRecord, u64, u64, PathBuf)> {
    let scratch = Scratch::beside(target, "join")?;
    let (checkpoint, files, bytes) = match authority.run(&OperatorRequest::FetchCheckpoint {
        archive: scratch.0.clone(),
    })? {
        OperatorReport::Fetched {
            checkpoint,
            files,
            bytes,
        } => (checkpoint, files, bytes),
        other => return Err(unexpected("fetch_checkpoint", &other)),
    };
    let restored = backup::restore(&scratch.0, target, script)?;
    ensure!(
        restored.coordinator_id == coordinator_id,
        "The checkpoint restored coordinator {}, not {coordinator_id}",
        restored.coordinator_id
    );
    Ok((checkpoint, files, bytes, restored.state_dir))
}

/// Applies new log entries and their files to a standby. With `interval` it
/// polls until the process is interrupted, reports each pass that applied
/// something, and waits out an authority that does not answer.
pub fn follow(
    state: &Path,
    script: &Path,
    config: &FailoverConfig,
    interval: Option<Duration>,
    mut report: impl FnMut(&Followed) -> Result<()>,
) -> Result<()> {
    holder(config)?;
    let (lock, coordinator_id) = lock_state(state)?;
    let authority = Authority::open(script, config, coordinator_id)?;
    loop {
        match apply_log(&authority, &lock, state) {
            Ok((from, applied)) => {
                if interval.is_none() || applied != from {
                    report(&Followed {
                        coordinator_id,
                        from,
                        applied,
                    })?;
                }
            }
            Err(error) if interval.is_some() && error.is::<AuthorityUnreachable>() => {
                eprintln!("{error:#}");
            }
            Err(error) => return Err(error),
        }
        match interval {
            Some(interval) => thread::sleep(interval),
            None => return Ok(()),
        }
    }
}

fn apply_log(
    authority: &Authority,
    lock: &WriterLock,
    state: &Path,
) -> Result<(LogPosition, LogPosition)> {
    match authority.write(
        lock,
        &OperatorRequest::Follow {
            state: state.to_owned(),
        },
    )? {
        OperatorReport::Followed { from, applied } => Ok((from, applied)),
        other => Err(unexpected("follow", &other)),
    }
}

/// The one place that posts `lock_held`, for `failover release` and for a
/// sealed holder that restarts. The writer lock proves that no supervisor and
/// no Pi child of the state directory is alive. The exclusive `effects.lock`
/// proves the same of every local effect process, after the recorded process
/// groups that were still alive were stopped. A survivor is an error, and
/// nothing is posted.
pub(crate) fn release_by_lock(
    lock: &WriterLock,
    state: &Path,
    operator: &FailoverOperator,
    session: &FailoverSession,
    holder: HolderId,
    epoch: OwnerEpoch,
) -> Result<()> {
    let _stopped = effects::stop_survivors(lock, state)?;
    let command = AuthorityCommand::Release {
        holder,
        epoch,
        evidence: ReleaseEvidence::LockHeld,
    };
    match operator.run(session, &OperatorRequest::Authority { command })? {
        OperatorReport::Reply {
            reply: AuthorityReply::Accepted { .. },
        } => Ok(()),
        OperatorReport::Reply {
            reply: AuthorityReply::Refused { reason, state },
        } => Err(Refused {
            action: "this release",
            reason,
            state,
        }
        .into()),
        other => Err(unexpected("authority", &other)),
    }
}

/// On the old owner's host: proves that no supervisor, Pi child or local
/// effect process of this state directory is alive, and says so.
pub fn release(state: &Path, script: &Path, config: &FailoverConfig) -> Result<Released> {
    let holder = holder(config)?;
    let (lock, coordinator_id) = lock_state(state)?;
    let authority = Authority::open(script, config, coordinator_id)?;
    let record = authority.enrolled()?;
    let AuthorityState::Sealed {
        epoch,
        holder: sealed,
        candidate,
        ..
    } = record.state
    else {
        return Err(Refused {
            action: "this release",
            reason: AuthorityRefusal::NotSealed,
            state: Some(record.state),
        }
        .into());
    };
    if sealed != holder {
        return Err(Refused {
            action: "this release",
            reason: AuthorityRefusal::NotSealedHolder,
            state: Some(record.state),
        }
        .into());
    }
    release_by_lock(
        &lock,
        state,
        &authority.operator,
        &authority.session,
        holder,
        epoch,
    )?;
    Ok(Released {
        coordinator_id,
        epoch,
        evidence: ReleaseEvidence::LockHeld,
        candidate,
    })
}

/// The stop evidence of an owner that saw its epoch fenced and has finished
/// its cleanup. It posts `released` only when the record is sealed at `epoch`
/// with `session`'s holder, and answers whether it posted.
pub(crate) async fn post_released(
    script: &Path,
    session: &FailoverSession,
    epoch: OwnerEpoch,
    limit: Duration,
) -> Result<bool> {
    let Some(holder) = session.holder else {
        return Ok(false);
    };
    let operator = FailoverOperator::locate(script)?;
    let session = FailoverSession {
        epoch: None,
        ..session.clone()
    };
    let record = match operator
        .run_within(&session, &OperatorRequest::Status { state: None }, limit)
        .await?
    {
        OperatorReport::Status { record, .. } => record,
        other => return Err(unexpected("status", &other)),
    };
    let sealed_here = matches!(
        record,
        Some(AuthorityRecord {
            state: AuthorityState::Sealed { epoch: sealed_at, holder: sealed, .. },
            ..
        }) if sealed_at == epoch && sealed == holder
    );
    if !sealed_here {
        return Ok(false);
    }
    let command = AuthorityCommand::Release {
        holder,
        epoch,
        evidence: ReleaseEvidence::Released,
    };
    match operator
        .run_within(&session, &OperatorRequest::Authority { command }, limit)
        .await?
    {
        OperatorReport::Reply {
            reply: AuthorityReply::Accepted { .. },
        } => Ok(true),
        OperatorReport::Reply {
            reply: AuthorityReply::Refused { reason, state },
        } => Err(Refused {
            action: "this release",
            reason,
            state,
        }
        .into()),
        other => Err(unexpected("authority", &other)),
    }
}

pub struct Promotion {
    /// The epoch the operator saw and means to replace.
    pub replace_epoch: OwnerEpoch,
    /// The operator's statement that the old owner is stopped.
    pub old_owner_stopped: Option<String>,
    /// How long to wait for stop evidence.
    pub wait: Duration,
    /// Whether this host's config has an `[apns]` section.
    pub apns_configured: bool,
}

/// Makes this standby the owner: seal, stop evidence, catch-up and
/// verification, then activation.
pub fn promote(
    state: &Path,
    script: &Path,
    config: &FailoverConfig,
    promotion: Promotion,
) -> Result<Promoted> {
    let holder = holder(config)?;
    let (lock, coordinator_id) = lock_state(state)?;
    let authority = Authority::open(script, config, coordinator_id)?;
    let record = authority.enrolled()?;
    let owned =
        matches!(record.state, AuthorityState::Active { holder: owner, .. } if owner == holder);
    let (evidence, applied) = if owned {
        (None, state_head(&record.state))
    } else {
        if state_epoch(&record.state) != promotion.replace_epoch {
            return Err(Refused {
                action: "this promotion",
                reason: AuthorityRefusal::EpochMoved,
                state: Some(record.state),
            }
            .into());
        }
        let sealed = authority.command(
            "this promotion",
            AuthorityCommand::Promote {
                candidate: holder,
                expected_epoch: promotion.replace_epoch,
                attestation: promotion.old_owner_stopped,
            },
        )?;
        let (evidence, head) = stop_evidence(&authority, holder, sealed, promotion.wait)?;
        apply_log(&authority, &lock, state)?;
        let applied = match authority.run(&OperatorRequest::Verify {
            state: state.to_owned(),
        })? {
            OperatorReport::Verified { applied, .. } => applied,
            other => return Err(unexpected("verify", &other)),
        };
        ensure!(
            applied == head,
            "{} holds the log through position {}, and the sealed head is {}",
            state.display(),
            applied.get(),
            head.get()
        );
        (Some(evidence), applied)
    };
    let active = authority.command(
        "this activation",
        AuthorityCommand::Activate {
            candidate: holder,
            applied,
        },
    )?;
    let AuthorityState::Active { epoch, head, .. } = active else {
        bail!("The authority accepted the activation and reported no owner");
    };
    backup::release_locked(&lock, state)?;
    let (unfinished_tools, unfinished_deliveries, unreadable) =
        match authority.run(&OperatorRequest::Unfinished {
            state: state.to_owned(),
        })? {
            OperatorReport::Unfinished {
                tools,
                deliveries,
                unreadable,
            } => (tools, deliveries, unreadable),
            other => return Err(unexpected("unfinished", &other)),
        };
    let mut missing_credentials = Vec::new();
    if !state.join("auth.json").is_file() {
        missing_credentials.push("auth.json");
    }
    if !promotion.apns_configured {
        missing_credentials.push("[apns]");
    }
    Ok(Promoted {
        coordinator_id,
        holder,
        epoch,
        sealed_head: head,
        evidence,
        missing_credentials,
        unfinished_tools,
        unfinished_deliveries,
        unreadable,
    })
}

/// Waits until the authority holds stop evidence for this candidate. A sealed
/// holder that promotes itself holds its own writer lock, which is that
/// evidence. The end of the wait is never evidence.
fn stop_evidence(
    authority: &Authority,
    holder: HolderId,
    mut state: AuthorityState,
    wait: Duration,
) -> Result<(StopEvidence, LogPosition)> {
    let deadline = Instant::now() + wait;
    loop {
        match state {
            AuthorityState::Vacant {
                candidate,
                evidence,
                head,
                ..
            } if candidate == holder => return Ok((evidence, head)),
            AuthorityState::Sealed {
                epoch,
                holder: sealed,
                candidate,
                ..
            } if candidate == holder => {
                if sealed == holder {
                    state = authority.command(
                        "this release",
                        AuthorityCommand::Release {
                            holder,
                            epoch,
                            evidence: ReleaseEvidence::LockHeld,
                        },
                    )?;
                    continue;
                }
                ensure!(
                    Instant::now() < deadline,
                    "The old owner gave no stop evidence within {} seconds, so the log stays sealed at epoch {} and nothing was promoted. Run `beep-boop failover release` on the host of holder {}, then run this command again. If that host cannot be reached, run this command again with --old-owner-stopped \"<why you take the old owner to be stopped>\"",
                    wait.as_secs(),
                    epoch.get(),
                    sealed.get()
                );
            }
            other => {
                return Err(Refused {
                    action: "this promotion",
                    reason: AuthorityRefusal::NotCandidate,
                    state: Some(other),
                }
                .into());
            }
        }
        thread::sleep(EVIDENCE_POLL);
        state = authority.enrolled()?.state;
    }
}

fn state_epoch(state: &AuthorityState) -> OwnerEpoch {
    match state {
        AuthorityState::Active { epoch, .. }
        | AuthorityState::Sealed { epoch, .. }
        | AuthorityState::Vacant { epoch, .. } => *epoch,
    }
}

fn state_head(state: &AuthorityState) -> LogPosition {
    match state {
        AuthorityState::Active { head, .. }
        | AuthorityState::Sealed { head, .. }
        | AuthorityState::Vacant { head, .. } => *head,
    }
}
