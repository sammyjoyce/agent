//! The right of this process to run a coordinator, taken before any setup.

use std::{
    fmt,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result, bail};

use crate::{
    coordinator_id::CoordinatorId,
    failover::{
        AuthorityRefusal, AuthorityState, FailoverConfig, FailoverHelper, FailoverOperator,
        FailoverReport, FailoverRequest, FailoverSession, HolderId, OwnerEpoch,
    },
    runtime::{
        WriterLock,
        effects::{EffectsLock, SurvivingEffects},
    },
};

/// Proof that this process may run a coordinator. `Runtime::start` requires
/// one, and only `acquire` makes one.
pub struct OwnerClaim {
    state: PathBuf,
    lock: WriterLock,
    /// Declared after `lock`, so the writer lock is freed first and a release
    /// that takes it finds this share still held until this process is done.
    _effects: Option<EffectsLock>,
    coordinator_id: CoordinatorId,
    authority: Authority,
}

enum Authority {
    /// No `[failover]` section: the writer lock alone decides.
    Local,
    Replicated {
        epoch: OwnerEpoch,
        session: FailoverSession,
    },
}

impl OwnerClaim {
    /// Takes `writer.lock`, then the coordinator identity. With a `[failover]`
    /// section, asks the authority for the next epoch through the runtime's
    /// helper and never mints an identity. A state directory that holds no
    /// log position is refused before any epoch is asked for.
    pub fn acquire(state: &Path, script: &Path, failover: Option<&FailoverConfig>) -> Result<Self> {
        let Some(failover) = failover else {
            let lock = WriterLock::acquire(state)?;
            // Only a replicated owner's release reads this lock, so a start
            // without failover never fails on it.
            let effects = EffectsLock::share(state)
                .inspect_err(|error| eprintln!("Local effect processes are not tracked: {error:#}"))
                .ok();
            return Ok(Self {
                state: state.to_owned(),
                coordinator_id: CoordinatorId::load_or_mint(state)?,
                lock,
                _effects: effects,
                authority: Authority::Local,
            });
        };
        let holder = failover.holder.context(
            "This host's [failover] section has no holder, so it only watches the owner record and is not a coordinator",
        )?;
        let lock = WriterLock::acquire(state)?;
        let coordinator_id = CoordinatorId::read(state)?.with_context(|| {
            format!(
                "{} has no coordinator-id, and a failover coordinator never mints one. Run `beep-boop failover enroll` to enroll this state directory as a replicated coordinator, or `beep-boop failover join` to make it a standby of an enrolled one",
                state.display()
            )
        })?;
        let session = FailoverSession {
            url: failover.url.clone(),
            token_file: failover.token_file.clone(),
            coordinator_id,
            holder: Some(holder),
            epoch: None,
        };
        let claim = FailoverRequest::Claim {
            state: state.to_owned(),
        };
        // The helper holds the writer lock too. One that outlives this
        // process could otherwise read the epoch after the next start claimed,
        // claim that newer epoch, and fence the coordinator that replaced it.
        match FailoverHelper::locate(script)?.run_holding(&lock, &session, &claim)? {
            FailoverReport::Claimed { epoch, .. } => Ok(Self {
                state: state.to_owned(),
                _effects: Some(EffectsLock::share(state)?),
                lock,
                coordinator_id,
                authority: Authority::Replicated { epoch, session },
            }),
            FailoverReport::Refused {
                reason: AuthorityRefusal::EpochMoved,
                ..
            } => bail!(
                "Another start of this coordinator's holder claimed an epoch while this start was claiming, so this start claimed nothing and is not the owner. Start the coordinator again"
            ),
            FailoverReport::Refused {
                reason,
                state: record,
            } => {
                if let Some(AuthorityState::Sealed {
                    epoch,
                    holder: sealed,
                    ..
                }) = record
                    && sealed == holder
                {
                    post_lock_held_after_refused_start(
                        &lock, state, script, &session, holder, epoch,
                    );
                }
                Err(OwnerFenced::Refused {
                    reason,
                    state: record,
                }
                .into())
            }
            FailoverReport::Unstamped => bail!(
                "{} holds no replication position, so this coordinator cannot start as the replicated owner and claimed nothing. Run `beep-boop failover enroll` to enroll this state directory as a replicated coordinator, or `beep-boop failover join` to make it a standby of an enrolled one",
                state.display()
            ),
            FailoverReport::Record { .. } => {
                bail!("The failover helper answered a claim with the owner record")
            }
        }
    }

    pub fn state(&self) -> &Path {
        &self.state
    }

    pub fn coordinator_id(&self) -> CoordinatorId {
        self.coordinator_id
    }

    pub fn epoch(&self) -> Option<OwnerEpoch> {
        match &self.authority {
            Authority::Local => None,
            Authority::Replicated { epoch, .. } => Some(*epoch),
        }
    }

    pub(crate) fn lock(&self) -> &WriterLock {
        &self.lock
    }

    pub(crate) fn pi_session(&self) -> Option<FailoverSession> {
        match &self.authority {
            Authority::Local => None,
            Authority::Replicated { epoch, session } => Some(FailoverSession {
                epoch: Some(*epoch),
                ..session.clone()
            }),
        }
    }
}

/// A sealed holder that restarts says by itself that it is stopped, so the
/// promotion that sealed it need not wait for an operator.
fn post_lock_held_after_refused_start(
    lock: &WriterLock,
    state: &Path,
    script: &Path,
    session: &FailoverSession,
    holder: HolderId,
    epoch: OwnerEpoch,
) {
    let posted = FailoverOperator::locate(script).and_then(|operator| {
        crate::failover::commands::release_by_lock(lock, state, &operator, session, holder, epoch)
    });
    match posted {
        Ok(()) => eprintln!(
            "Told the failover authority that no process of this coordinator is alive at epoch {}",
            epoch.get()
        ),
        // A survivor's own sentence already says what an operator can do.
        Err(error) if error.is::<SurvivingEffects>() => eprintln!(
            "Did not tell the failover authority that this coordinator is stopped. {error:#}"
        ),
        Err(error) => eprintln!(
            "Could not tell the failover authority that this coordinator is stopped: {error:#}. Run `beep-boop failover release` on this host"
        ),
    }
}

/// This host does not own the coordinator. `main` ends the process with
/// `OWNER_FENCED_EXIT` for this error and for no other.
#[derive(Debug)]
pub enum OwnerFenced {
    /// The authority refused this start's claim.
    Refused {
        reason: AuthorityRefusal,
        state: Option<AuthorityState>,
    },
    /// The Pi child found its epoch fenced and exited with `OWNER_FENCED_EXIT`.
    Runtime,
}

impl fmt::Display for OwnerFenced {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let (reason, state) = match self {
            Self::Runtime => {
                return f.write_str(
                    "The Pi runtime stopped because the failover authority fenced this coordinator's epoch",
                );
            }
            Self::Refused { reason, state } => (reason, state),
        };
        write!(
            f,
            "The failover authority refused this coordinator start ({reason:?}): "
        )?;
        match state {
            Some(state) => state.fmt(f),
            None => f.write_str("the authority has no record of this coordinator"),
        }
    }
}

impl std::error::Error for OwnerFenced {}
