//! The highest owner epoch this host has served for each coordinator. Every
//! worker daemon of the user shares one floor file per coordinator outside any
//! state directory, so neither a restarted daemon nor a second daemon with a
//! fresh state directory serves a replaced owner.

use std::{
    fmt,
    fs::{self, File, OpenOptions},
    io::{ErrorKind, Write},
    os::unix::fs::{DirBuilderExt, OpenOptionsExt},
    path::{Path, PathBuf},
    time::Duration,
};

use anyhow::{Context, Result, bail};

use crate::{
    coordinator_id::CoordinatorId,
    failover::{
        AuthorityRecord, AuthorityState, FailoverConfig, FailoverHelper, FailoverReport,
        FailoverRequest, FailoverSession, OwnerEpoch,
    },
};

const OWNER_FLOORS: &str = "beep-boop-owner-floors";

/// A record read that takes longer than this counts as a failed read.
const RECORD_READ_LIMIT: Duration = Duration::from_secs(30);

/// The floor files of this user, one per coordinator id, holding the epoch as decimal text.
pub struct OwnerFloor {
    directory: PathBuf,
}

/// What a coordinator says about itself when it accepts a worker link.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OwnerLink {
    /// A coordinator older than owner floors, which names neither itself nor an epoch.
    Unidentified,
    Identified {
        coordinator: CoordinatorId,
        epoch: Option<OwnerEpoch>,
    },
}

impl OwnerLink {
    /// The link `WorkerReady` describes. An epoch without an identity cannot be
    /// checked against any floor, so it counts as unidentified.
    pub fn new(coordinator: Option<CoordinatorId>, epoch: Option<OwnerEpoch>) -> Self {
        match coordinator {
            Some(coordinator) => Self::Identified { coordinator, epoch },
            None => Self::Unidentified,
        }
    }
}

/// This host has served a newer owner than the link offers.
#[derive(Debug)]
pub struct BelowFloor {
    link: OwnerLink,
    floored: CoordinatorId,
    floor: OwnerEpoch,
}

impl fmt::Display for BelowFloor {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let floor = self.floor.get();
        match self.link {
            OwnerLink::Identified {
                coordinator,
                epoch: Some(epoch),
            } => write!(
                f,
                "Refused coordinator {coordinator} at owner epoch {}: this host has served it at epoch {floor}, so a newer owner replaced it",
                epoch.get()
            ),
            OwnerLink::Identified {
                coordinator,
                epoch: None,
            } => write!(
                f,
                "Refused coordinator {coordinator} without an owner epoch: this host has served it at epoch {floor} under failover"
            ),
            OwnerLink::Unidentified => write!(
                f,
                "Refused a coordinator that names no identity, as versions before owner floors do: this host has served coordinator {} at epoch {floor}. Update that coordinator",
                self.floored
            ),
        }
    }
}

impl std::error::Error for BelowFloor {}

impl OwnerFloor {
    /// The floors under this user's local data directory.
    pub fn for_user() -> Result<Self> {
        let data = dirs::data_local_dir()
            .context("This user has no local data directory to keep owner floors in")?;
        Ok(Self {
            directory: data.join(OWNER_FLOORS),
        })
    }

    /// Admits a new link before it carries a call. A higher epoch is on disk
    /// before this returns. A link without an epoch never creates a file.
    pub fn admit(&self, link: OwnerLink) -> Result<()> {
        let OwnerLink::Identified {
            coordinator,
            epoch: Some(epoch),
        } = link
        else {
            return self.check(link);
        };
        let floor = self.update(coordinator, epoch)?;
        if floor > epoch {
            return Err(BelowFloor {
                link,
                floored: coordinator,
                floor,
            }
            .into());
        }
        Ok(())
    }

    /// Raises the floor to `epoch` when it is higher. Never lowers it.
    pub fn raise(&self, coordinator: CoordinatorId, epoch: OwnerEpoch) -> Result<()> {
        self.update(coordinator, epoch).map(drop)
    }

    /// Rechecks an admitted link, which another daemon or the owner watch may
    /// have left below the floor since. Writes nothing.
    pub fn check(&self, link: OwnerLink) -> Result<()> {
        let (floored, floor) = match link {
            OwnerLink::Unidentified => match self.any()? {
                Some(found) => found,
                None => return Ok(()),
            },
            OwnerLink::Identified { coordinator, epoch } => match self.read(coordinator)? {
                // A link with no epoch is below every floor.
                Some(floor) if epoch < Some(floor) => (coordinator, floor),
                _ => return Ok(()),
            },
        };
        Err(BelowFloor {
            link,
            floored,
            floor,
        }
        .into())
    }

    /// Writers replace the file whole, so a read needs no lock.
    fn read(&self, coordinator: CoordinatorId) -> Result<Option<OwnerEpoch>> {
        let path = self.directory.join(coordinator.to_string());
        let file = match OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&path)
        {
            Ok(file) => file,
            Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
            Err(error) => {
                return Err(error).with_context(|| format!("Could not open {}", path.display()));
            }
        };
        let text = std::io::read_to_string(file)
            .with_context(|| format!("Could not read {}", path.display()))?;
        let epoch = text
            .strip_suffix('\n')
            .filter(|digits| !digits.is_empty() && digits.bytes().all(|byte| byte.is_ascii_digit()))
            .and_then(|digits| digits.parse().ok())
            .and_then(|epoch| OwnerEpoch::new(epoch).ok());
        match epoch {
            Some(epoch) => Ok(Some(epoch)),
            None => bail!(
                "{} is not an owner floor, so this host serves that coordinator no effects until the file holds the highest epoch it served",
                path.display()
            ),
        }
    }

    /// The first floor found, for a coordinator that cannot say which one is its own.
    fn any(&self) -> Result<Option<(CoordinatorId, OwnerEpoch)>> {
        let entries = match fs::read_dir(&self.directory) {
            Ok(entries) => entries,
            Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("Could not list {}", self.directory.display()));
            }
        };
        for entry in entries {
            let name = entry?.file_name();
            let Some(coordinator) = name
                .to_str()
                .and_then(|name| name.parse::<CoordinatorId>().ok())
                .filter(|coordinator| name.to_str() == Some(&coordinator.to_string()))
            else {
                continue;
            };
            if let Some(floor) = self.read(coordinator)? {
                return Ok(Some((coordinator, floor)));
            }
        }
        Ok(None)
    }

    /// Under the coordinator's exclusive lock, puts `epoch` on disk when it is
    /// above the floor, and returns the floor that is on disk afterwards.
    fn update(&self, coordinator: CoordinatorId, epoch: OwnerEpoch) -> Result<OwnerEpoch> {
        self.create()?;
        let name = coordinator.to_string();
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(self.directory.join(format!("{name}.lock")))
            .context("Could not open the owner floor lock")?;
        fs2::FileExt::lock_exclusive(&lock).context("Could not lock the owner floor")?;
        if let Some(floor) = self.read(coordinator)?.filter(|floor| *floor >= epoch) {
            return Ok(floor);
        }
        let temporary = self.directory.join(format!("{name}.tmp"));
        let mut file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&temporary)
            .context("Could not write the owner floor")?;
        file.write_all(format!("{}\n", epoch.get()).as_bytes())?;
        file.sync_all()?;
        fs::rename(&temporary, self.directory.join(&name))
            .context("Could not save the owner floor")?;
        File::open(&self.directory)?.sync_all()?;
        Ok(epoch)
    }

    fn create(&self) -> Result<()> {
        let parent = self
            .directory
            .parent()
            .context("The owner floor directory has no parent")?;
        fs::create_dir_all(parent)?;
        match fs::DirBuilder::new().mode(0o700).create(&self.directory) {
            Ok(()) => Ok(File::open(parent)?.sync_all()?),
            Err(error) if error.kind() == ErrorKind::AlreadyExists => Ok(()),
            Err(error) => {
                Err(error).with_context(|| format!("Could not create {}", self.directory.display()))
            }
        }
    }
}

/// A worker's watch on the authority's owner record, from its `[failover]` section.
pub struct OwnerWatch {
    helper: FailoverHelper,
    failover: FailoverConfig,
}

impl OwnerWatch {
    pub fn new(failover: &FailoverConfig, script: &Path) -> Result<Self> {
        Ok(Self {
            helper: FailoverHelper::locate(script)?,
            failover: failover.clone(),
        })
    }

    /// Reads the record now and then once per interval. Returns only when the
    /// link is below this host's floor, because a record named a newer owner
    /// or another daemon raised the floor. A failed read changes nothing.
    pub async fn ended(&self, floor: &OwnerFloor, link: OwnerLink) -> anyhow::Error {
        let OwnerLink::Identified { coordinator, .. } = link else {
            return std::future::pending().await;
        };
        let session = FailoverSession {
            url: self.failover.url.clone(),
            token_file: self.failover.token_file.clone(),
            coordinator_id: coordinator,
            holder: self.failover.holder,
            epoch: None,
        };
        let mut ticks = tokio::time::interval(self.failover.watch_interval());
        ticks.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            ticks.tick().await;
            if let Some(epoch) = self.owner_epoch(&session).await
                && let Err(error) = floor.raise(coordinator, epoch)
            {
                return error;
            }
            if let Err(error) = floor.check(link) {
                return error;
            }
        }
    }

    /// Only an active record names an owner. A sealed or vacant one is between owners.
    async fn owner_epoch(&self, session: &FailoverSession) -> Option<OwnerEpoch> {
        match self
            .helper
            .run_within(session, &FailoverRequest::Record, RECORD_READ_LIMIT)
            .await
        {
            Ok(FailoverReport::Record {
                record:
                    Some(AuthorityRecord {
                        state: AuthorityState::Active { epoch, .. },
                        ..
                    }),
            }) => Some(epoch),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests;
