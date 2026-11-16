//! The right of this process to run a coordinator, taken before any setup.

use std::{
    fmt,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result, bail};

use crate::{
    coordinator_id::CoordinatorId,
    failover::{
        AuthorityCommand, AuthorityRefusal, AuthorityReply, AuthorityState, FailoverConfig,
        FailoverHelper, FailoverOperator, FailoverReport, FailoverRequest, FailoverSession,
        HolderId, OperatorReport, OperatorRequest, OwnerEpoch, ReleaseEvidence,
    },
    runtime::WriterLock,
};

/// Proof that this process may run a coordinator. `Runtime::start` requires
/// one, and only `acquire` makes one.
pub struct OwnerClaim {
    state: PathBuf,
    lock: WriterLock,
    coordinator_id: CoordinatorId,
    authority: Authority,
}

enum Authority {
    /// No `[failover]` section: the writer lock alone decides, as before failover.
    Local,
    /// The failover authority granted `epoch` to this start.
    Replicated {
        epoch: OwnerEpoch,
        session: FailoverSession,
    },
}

impl OwnerClaim {
    /// Takes `writer.lock`, then the coordinator identity. With a `[failover]`
    /// section, asks the authority for the next epoch through the runtime's
    /// helper and never mints an identity.
    pub fn acquire(state: &Path, script: &Path, failover: Option<&FailoverConfig>) -> Result<Self> {
        let Some(failover) = failover else {
            let lock = WriterLock::acquire(state)?;
            return Ok(Self {
                state: state.to_owned(),
                coordinator_id: CoordinatorId::load_or_mint(state)?,
                lock,
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
        match FailoverHelper::locate(script)?.run(&session, &FailoverRequest::Claim)? {
            FailoverReport::Claimed { epoch, .. } => Ok(Self {
                state: state.to_owned(),
                lock,
                coordinator_id,
                authority: Authority::Replicated { epoch, session },
            }),
            FailoverReport::Refused { reason, state } => {
                if let Some(AuthorityState::Sealed {
                    epoch,
                    holder: sealed,
                    ..
                }) = state
                    && sealed == holder
                {
                    release_by_lock(&lock, script, &session, holder, epoch);
                }
                Err(OwnerFenced::Refused { reason, state }.into())
            }
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

    /// The epoch the authority granted this start, under a replicated claim.
    pub fn epoch(&self) -> Option<OwnerEpoch> {
        match &self.authority {
            Authority::Local => None,
            Authority::Replicated { epoch, .. } => Some(*epoch),
        }
    }

    pub(crate) fn lock(&self) -> &WriterLock {
        &self.lock
    }

    /// The session the Pi child opens at the granted epoch, under a replicated claim.
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

/// A sealed holder that holds its writer lock has no supervisor and no Pi
/// child alive, so it says so, and the promotion that sealed it need not wait
/// for an operator. A failed post changes nothing: the start is still refused,
/// and `failover release` posts the same evidence.
fn release_by_lock(
    _lock: &WriterLock,
    script: &Path,
    session: &FailoverSession,
    holder: HolderId,
    epoch: OwnerEpoch,
) {
    let command = AuthorityCommand::Release {
        holder,
        epoch,
        evidence: ReleaseEvidence::LockHeld,
    };
    let posted = FailoverOperator::locate(script)
        .and_then(|operator| operator.run(session, &OperatorRequest::Authority { command }));
    match posted {
        Ok(OperatorReport::Reply {
            reply: AuthorityReply::Accepted { .. },
        }) => eprintln!(
            "Told the failover authority that no process of this coordinator is alive at epoch {}",
            epoch.get()
        ),
        Ok(report) => eprintln!(
            "The failover authority did not take this coordinator's release: {report:?}. Run `beep-boop failover release` on this host"
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
