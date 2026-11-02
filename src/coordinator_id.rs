use std::{
    fmt,
    fs::{self, File, OpenOptions},
    io::{ErrorKind, Write},
    os::unix::fs::OpenOptionsExt,
    path::Path,
};

use anyhow::{Context, Result, bail};

/// Persistent identity of one coordinator state directory, so a phone can tell
/// two coordinators apart and notice when fresh state replaced the one it knew.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CoordinatorId(uuid::Uuid);

const COORDINATOR_ID_FILE: &str = "coordinator-id";
const COORDINATOR_ID_TEMPORARY: &str = "coordinator-id.tmp";

impl CoordinatorId {
    /// Reads `<state>/coordinator-id`, or mints one. Call only while holding the
    /// state directory's writer lock, so two processes cannot mint two IDs.
    pub fn load_or_mint(state: &Path) -> Result<Self> {
        let path = state.join(COORDINATOR_ID_FILE);
        match OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&path)
        {
            Ok(file) => {
                let text = std::io::read_to_string(file)
                    .with_context(|| format!("Could not read {}", path.display()))?;
                match uuid::Uuid::try_parse(&text).map(Self) {
                    Ok(id) if id.to_string() == text => Ok(id),
                    _ => bail!(
                        "{} is not a coordinator ID; restore it instead of deleting it, because a new ID unpairs every phone",
                        path.display()
                    ),
                }
            }
            Err(error) if error.kind() == ErrorKind::NotFound => Self::mint(state),
            Err(error) => Err(error).with_context(|| format!("Could not open {}", path.display())),
        }
    }

    fn mint(state: &Path) -> Result<Self> {
        let id = Self(uuid::Uuid::new_v4());
        let temporary = state.join(COORDINATOR_ID_TEMPORARY);
        let mut file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&temporary)
            .context("Could not create the coordinator ID")?;
        file.write_all(id.to_string().as_bytes())?;
        file.sync_all()?;
        fs::rename(&temporary, state.join(COORDINATOR_ID_FILE))
            .context("Could not save the coordinator ID")?;
        File::open(state)?.sync_all()?;
        Ok(id)
    }
}

impl fmt::Display for CoordinatorId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.hyphenated().fmt(f)
    }
}

#[cfg(test)]
mod tests {
    use super::{COORDINATOR_ID_FILE, COORDINATOR_ID_TEMPORARY, CoordinatorId};
    use std::{fs, os::unix::fs::PermissionsExt};

    #[test]
    fn minted_id_is_private_canonical_and_reloads_unchanged() {
        let state = tempfile::tempdir().unwrap();
        let minted = CoordinatorId::load_or_mint(state.path()).unwrap();
        let path = state.path().join(COORDINATOR_ID_FILE);
        let text = fs::read_to_string(&path).unwrap();
        assert_eq!(text, minted.to_string());
        assert_eq!(uuid::Uuid::parse_str(&text).unwrap().get_version_num(), 4);
        assert_eq!(text, text.to_lowercase());
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(CoordinatorId::load_or_mint(state.path()).unwrap(), minted);
        assert_eq!(fs::read_to_string(&path).unwrap(), text);
    }

    #[test]
    fn separate_state_directories_have_different_ids() {
        let work = tempfile::tempdir().unwrap();
        let personal = tempfile::tempdir().unwrap();
        assert_ne!(
            CoordinatorId::load_or_mint(work.path()).unwrap(),
            CoordinatorId::load_or_mint(personal.path()).unwrap()
        );
    }

    #[test]
    fn malformed_id_is_an_error_and_is_never_replaced() {
        let valid = "0f5a3c2e-7b1d-4e8f-9a6b-1c2d3e4f5a6b";
        for malformed in [
            String::new(),
            "not a coordinator".into(),
            format!("{valid}\n"),
            valid.to_uppercase(),
            valid.replace('-', ""),
        ] {
            let state = tempfile::tempdir().unwrap();
            let path = state.path().join(COORDINATOR_ID_FILE);
            fs::write(&path, &malformed).unwrap();
            let error = CoordinatorId::load_or_mint(state.path()).unwrap_err();
            assert!(
                error.to_string().contains("is not a coordinator ID"),
                "{error:#}"
            );
            assert_eq!(fs::read_to_string(&path).unwrap(), malformed);
        }
    }

    #[test]
    fn leftover_temporary_file_from_a_crashed_mint_is_ignored() {
        let state = tempfile::tempdir().unwrap();
        fs::write(
            state.path().join(COORDINATOR_ID_TEMPORARY),
            "0f5a3c2e-7b1d-4e8f",
        )
        .unwrap();
        let minted = CoordinatorId::load_or_mint(state.path()).unwrap();
        assert!(!state.path().join(COORDINATOR_ID_TEMPORARY).exists());
        assert_eq!(CoordinatorId::load_or_mint(state.path()).unwrap(), minted);
    }
}
