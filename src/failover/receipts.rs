//! What each `beep-boop failover` command reports: the receipt it prints as
//! JSON, and the same receipt as text for a person.

use std::{fmt, path::PathBuf};

use serde::Serialize;

use super::{
    AuthorityRecord, AuthorityState, CheckpointRecord, HolderId, LogPosition, OwnerEpoch,
    ReleaseEvidence, StopEvidence, UnfinishedDelivery, UnfinishedToolCall,
};
use crate::coordinator_id::CoordinatorId;

#[derive(Debug, Serialize)]
pub struct Status {
    pub coordinator_id: CoordinatorId,
    /// Null before enrollment.
    pub record: Option<AuthorityRecord>,
    pub state_dir: PathBuf,
    /// The log position the state directory holds, or null when it holds none.
    pub applied: Option<LogPosition>,
}

impl fmt::Display for Status {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.record {
            None => write!(
                f,
                "The authority has no record of coordinator {}.",
                self.coordinator_id
            )?,
            Some(AuthorityRecord { state, checkpoint }) => {
                write!(f, "Coordinator {} is ", self.coordinator_id)?;
                let head = match state {
                    AuthorityState::Active {
                        epoch,
                        holder,
                        head,
                    } => {
                        write!(
                            f,
                            "active at epoch {}, owned by holder {}",
                            epoch.get(),
                            holder.get()
                        )?;
                        head
                    }
                    AuthorityState::Sealed {
                        epoch,
                        holder,
                        candidate,
                        head,
                    } => {
                        write!(
                            f,
                            "sealed at epoch {}: holder {} replaces holder {} and waits for stop evidence",
                            epoch.get(),
                            candidate.get(),
                            holder.get()
                        )?;
                        head
                    }
                    AuthorityState::Vacant {
                        epoch,
                        candidate,
                        evidence,
                        head,
                    } => {
                        write!(
                            f,
                            "vacant after epoch {} for holder {}. Stop evidence: {evidence}",
                            epoch.get(),
                            candidate.get()
                        )?;
                        head
                    }
                };
                write!(
                    f,
                    ". The log head is {} and the checkpoint is at {} (manifest {}).",
                    head.get(),
                    checkpoint.through.get(),
                    checkpoint.manifest.as_str()
                )?;
            }
        }
        match self.applied {
            Some(applied) => write!(
                f,
                " {} holds the log through position {}.",
                self.state_dir.display(),
                applied.get()
            ),
            None => write!(f, " {} holds no log position.", self.state_dir.display()),
        }
    }
}

impl fmt::Display for StopEvidence {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Released => f.write_str("the old owner stopped its effects and released"),
            Self::LockHeld => f.write_str("the old host's writer lock was taken"),
            Self::OperatorAttested { statement } => write!(f, "the operator stated: {statement}"),
        }
    }
}

#[derive(Debug, Serialize)]
pub struct Uploaded {
    pub files: u64,
    pub bytes: u64,
    pub not_included: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct Enrolled {
    pub coordinator_id: CoordinatorId,
    pub holder: HolderId,
    pub epoch: OwnerEpoch,
    pub checkpoint: CheckpointRecord,
    /// Null when this holder had already enrolled this directory, so nothing changed.
    pub uploaded: Option<Uploaded>,
}

impl fmt::Display for Enrolled {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.uploaded {
            Some(uploaded) => {
                write!(
                    f,
                    "Enrolled coordinator {} with holder {} as its owner at epoch {}. The checkpoint at position 0 holds {} files, {} bytes.",
                    self.coordinator_id,
                    self.holder.get(),
                    self.epoch.get(),
                    uploaded.files,
                    uploaded.bytes
                )?;
                if !uploaded.not_included.is_empty() {
                    write!(f, " Not included: {}.", uploaded.not_included.join(", "))?;
                }
                Ok(())
            }
            None => write!(
                f,
                "Coordinator {} is already enrolled with holder {} as its owner at epoch {}. Nothing changed.",
                self.coordinator_id,
                self.holder.get(),
                self.epoch.get()
            ),
        }
    }
}

#[derive(Debug, Serialize)]
pub struct Checkpointed {
    pub coordinator_id: CoordinatorId,
    pub epoch: OwnerEpoch,
    pub checkpoint: CheckpointRecord,
    pub head: LogPosition,
    pub uploaded: Uploaded,
}

impl fmt::Display for Checkpointed {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "Stored a checkpoint of coordinator {} at position {} ({} files, {} bytes) as its owner at epoch {}. The log head is {}.",
            self.coordinator_id,
            self.checkpoint.through.get(),
            self.uploaded.files,
            self.uploaded.bytes,
            self.epoch.get(),
            self.head.get()
        )?;
        if !self.uploaded.not_included.is_empty() {
            write!(
                f,
                " Not included: {}.",
                self.uploaded.not_included.join(", ")
            )?;
        }
        Ok(())
    }
}

#[derive(Debug, Serialize)]
pub struct Joined {
    pub coordinator_id: CoordinatorId,
    pub state_dir: PathBuf,
    pub through: LogPosition,
    pub files: u64,
    pub bytes: u64,
    /// Where `--replace` moved the directory that was there before.
    pub replaced: Option<PathBuf>,
}

impl fmt::Display for Joined {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "Joined coordinator {} as a standby in {} at position {} ({} files, {} bytes). `beep-boop failover follow` keeps it current, and it stays held until `beep-boop failover promote`.",
            self.coordinator_id,
            self.state_dir.display(),
            self.through.get(),
            self.files,
            self.bytes
        )?;
        match &self.replaced {
            Some(replaced) => write!(
                f,
                " The directory that was there is now {}.",
                replaced.display()
            ),
            None => Ok(()),
        }
    }
}

#[derive(Debug, Serialize)]
pub struct Followed {
    pub coordinator_id: CoordinatorId,
    pub from: LogPosition,
    pub applied: LogPosition,
}

impl fmt::Display for Followed {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.from == self.applied {
            write!(
                f,
                "The standby of coordinator {} already holds the log through position {}.",
                self.coordinator_id,
                self.applied.get()
            )
        } else {
            write!(
                f,
                "Applied log entries {} to {} to the standby of coordinator {}.",
                self.from.get() + 1,
                self.applied.get(),
                self.coordinator_id
            )
        }
    }
}

#[derive(Debug, Serialize)]
pub struct Released {
    pub coordinator_id: CoordinatorId,
    pub epoch: OwnerEpoch,
    pub evidence: ReleaseEvidence,
    pub candidate: HolderId,
    /// False when the authority already held this evidence, so this command
    /// posted nothing.
    pub posted: bool,
}

impl fmt::Display for Released {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.posted {
            write!(
                f,
                "Released coordinator {} at epoch {}: no process of this state directory is alive.",
                self.coordinator_id,
                self.epoch.get(),
            )?;
        } else {
            write!(
                f,
                "The authority already holds the old owner's stop evidence for coordinator {} at epoch {}, so this command posted nothing.",
                self.coordinator_id,
                self.epoch.get(),
            )?;
        }
        write!(
            f,
            " Holder {} can now finish `beep-boop failover promote`.",
            self.candidate.get()
        )
    }
}

#[derive(Debug, Serialize)]
pub struct Promoted {
    pub coordinator_id: CoordinatorId,
    pub holder: HolderId,
    pub epoch: OwnerEpoch,
    pub sealed_head: LogPosition,
    /// Null when this holder already owned the coordinator, so the record no
    /// longer holds the evidence.
    pub evidence: Option<StopEvidence>,
    /// Credentials that do not replicate and that this host lacks.
    pub missing_credentials: Vec<&'static str>,
    /// Tool calls the old epoch started and did not finish.
    pub unfinished_tools: Vec<UnfinishedToolCall>,
    /// Phone notifications the old epoch claimed and did not finish.
    pub unfinished_deliveries: Vec<UnfinishedDelivery>,
    /// Stored records the report could not read.
    pub unreadable: Vec<String>,
}

impl fmt::Display for Promoted {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "Holder {} owns coordinator {} at epoch {}. The sealed log head is {}.",
            self.holder.get(),
            self.coordinator_id,
            self.epoch.get(),
            self.sealed_head.get()
        )?;
        match &self.evidence {
            Some(evidence) => write!(f, "\nStop evidence: {evidence}")?,
            None => f.write_str(
                "\nThis holder already owned the coordinator, so the record holds no stop evidence.",
            )?,
        }
        if !self.missing_credentials.is_empty() {
            write!(
                f,
                "\nThis host lacks credentials that do not replicate: {}.",
                self.missing_credentials.join(", ")
            )?;
        }
        for call in &self.unfinished_tools {
            write!(
                f,
                "\nUnfinished tool call {} of {} in conversation {}: {}.",
                call.call_id,
                call.tool,
                call.conversation_id,
                if call.replay_safe {
                    "replay-safe, so the next start runs it again"
                } else {
                    "the next start reports it as interrupted and does not run it again"
                }
            )?;
        }
        for delivery in &self.unfinished_deliveries {
            write!(
                f,
                "\nUnfinished phone notification {} for entry {} in conversation {} to installation {}: the next start marks it uncertain and does not send it again.",
                delivery.apns_id,
                delivery.entry_id,
                delivery.conversation_id,
                delivery.installation_id
            )?;
        }
        for sentence in &self.unreadable {
            write!(f, "\n{sentence}")?;
        }
        f.write_str("\nStart the coordinator with `beep-boop serve`.")
    }
}
