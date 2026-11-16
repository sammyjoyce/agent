use std::{
    collections::BTreeSet,
    path::{Path, PathBuf},
    time::Duration,
};

use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::dreams::{HOST_TIMEOUT_MS, MAX_WINDOW_HOURS};

const DEFAULT_WINDOW_HOURS: u8 = 24;
const MAX_CHECK_SECONDS: u16 = 600;
const MAX_PATH_BYTES: usize = 512;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct DreamsPolicyFile {
    pub repository: PathBuf,
    /// Repository-relative globs; `*` matches within one path component.
    pub editable: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window_hours: Option<u8>,
    #[serde(default)]
    pub checks: Vec<DreamsCheckFile>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct DreamsCheckFile {
    pub name: String,
    pub argv: Vec<String>,
    pub timeout_seconds: u16,
}

/// Paths a Dreams proposal must never be able to reach through its target.
pub struct ProtectedPaths<'a> {
    pub config: Option<&'a Path>,
    pub job_directories: &'a [PathBuf],
}

#[derive(Clone, Debug)]
pub struct CheckSpec {
    pub name: String,
    pub argv: Vec<String>,
    pub timeout: Duration,
}

/// A repository-relative path the policy allows a proposal to change.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct EditablePath(String);
impl EditablePath {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}
impl std::fmt::Display for EditablePath {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

#[derive(Clone, Debug)]
struct Glob(Vec<String>);

/// Parsed policy. Invariants: the repository is an absolute, canonical Git
/// work tree that holds none of the protected paths; every editable glob is
/// relative and can never match a `.git*` component; checks are non-empty,
/// uniquely named, bounded in time, and name no editable path.
#[derive(Clone, Debug)]
pub struct DreamsPolicy {
    repository: PathBuf,
    editable: Vec<Glob>,
    window: Duration,
    checks: Vec<CheckSpec>,
    digest: String,
}

/// A small ASCII alphabet keeps a path free of controls, of the ignorable code
/// points some file systems fold into `.git`, and of anything Git would quote
/// in a patch header. `extra` admits the wildcard in a policy glob.
fn components<'a>(path: &'a str, extra: &[u8]) -> Result<Vec<&'a str>, String> {
    if path.is_empty() || path.len() > MAX_PATH_BYTES {
        return Err(format!("needs 1 to {MAX_PATH_BYTES} bytes"));
    }
    if !path.bytes().all(|byte| {
        byte.is_ascii_alphanumeric() || b"._-/ +@,".contains(&byte) || extra.contains(&byte)
    }) {
        return Err("may use only ASCII letters, digits, spaces and . _ - / + @ ,".into());
    }
    let parts: Vec<&str> = path.split('/').collect();
    for part in &parts {
        if part.is_empty() || *part == "." || *part == ".." {
            return Err("must be relative without empty, . or .. components".into());
        }
        if part.to_ascii_lowercase().starts_with(".git") {
            return Err("must not name Git metadata".into());
        }
    }
    Ok(parts)
}

fn resolved(path: &Path) -> PathBuf {
    for ancestor in path.ancestors() {
        if let Ok(canonical) = ancestor.canonicalize() {
            return match path.strip_prefix(ancestor) {
                Ok(rest) => canonical.join(rest),
                Err(_) => canonical,
            };
        }
    }
    path.to_owned()
}

fn wildcard(pattern: &[u8], text: &[u8]) -> bool {
    match pattern.split_first() {
        None => text.is_empty(),
        Some((b'*', rest)) => (0..=text.len()).any(|skip| wildcard(rest, &text[skip..])),
        Some((byte, rest)) => text
            .split_first()
            .is_some_and(|(first, tail)| first == byte && wildcard(rest, tail)),
    }
}

impl Glob {
    fn parse(text: &str) -> Result<Self> {
        let parts = components(text, b"*")
            .map_err(|reason| anyhow::anyhow!("Dreams editable glob {text:?} {reason}"))?;
        Ok(Self(parts.into_iter().map(str::to_owned).collect()))
    }
    fn matches(&self, parts: &[&str]) -> bool {
        self.0.len() == parts.len()
            && self
                .0
                .iter()
                .zip(parts)
                .all(|(pattern, part)| wildcard(pattern.as_bytes(), part.as_bytes()))
    }
}

impl DreamsPolicy {
    pub fn parse(file: &DreamsPolicyFile, protected: &ProtectedPaths) -> Result<Self> {
        ensure!(
            file.repository.is_absolute(),
            "Dreams repository needs an absolute path or a ~/ path"
        );
        let repository = file
            .repository
            .canonicalize()
            .with_context(|| format!("Dreams repository {:?} is unavailable", file.repository))?;
        ensure!(
            repository.join(".git").exists(),
            "Dreams repository {repository:?} is not the root of a Git work tree"
        );
        let inside = |path: &Path| resolved(path).starts_with(&repository);
        ensure!(
            !protected.config.is_some_and(inside),
            "Dreams repository must not contain the configuration file"
        );
        ensure!(
            !protected
                .job_directories
                .iter()
                .any(|directory| inside(directory)),
            "Dreams repository must not contain a job directory"
        );

        ensure!(
            !file.editable.is_empty(),
            "Dreams needs at least one editable glob"
        );
        let editable = file
            .editable
            .iter()
            .map(|glob| Glob::parse(glob))
            .collect::<Result<Vec<_>>>()?;

        let hours = file.window_hours.unwrap_or(DEFAULT_WINDOW_HOURS);
        ensure!(
            (1..=MAX_WINDOW_HOURS).contains(&hours),
            "Dreams window_hours must be between 1 and {MAX_WINDOW_HOURS}"
        );

        ensure!(
            !file.checks.is_empty(),
            "Dreams needs at least one check for its before and after evidence"
        );
        let mut names = BTreeSet::new();
        let mut checks = Vec::new();
        let policy = Self {
            repository,
            editable,
            window: Duration::from_secs(u64::from(hours) * 60 * 60),
            checks: Vec::new(),
            digest: String::new(),
        };
        for check in &file.checks {
            ensure!(
                !check.name.is_empty()
                    && check.name.len() <= 64
                    && check
                        .name
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || b"_-.".contains(&byte)),
                "Dreams check names use 1 to 64 letters, digits, _, - or ."
            );
            ensure!(
                names.insert(check.name.as_str()),
                "Dreams check {} is defined twice",
                check.name
            );
            ensure!(
                check
                    .argv
                    .first()
                    .is_some_and(|program| !program.is_empty())
                    && check.argv.iter().all(|argument| !argument.contains('\0')),
                "Dreams check {} needs a program and valid arguments",
                check.name
            );
            ensure!(
                (1..=MAX_CHECK_SECONDS).contains(&check.timeout_seconds),
                "Dreams check {} needs a timeout between 1 and {MAX_CHECK_SECONDS} seconds",
                check.name
            );
            for argument in &check.argv {
                let relative = Path::new(argument)
                    .strip_prefix(&policy.repository)
                    .ok()
                    .and_then(Path::to_str)
                    .unwrap_or(argument.trim_start_matches("./"));
                if policy.editable(relative).is_ok() {
                    bail!(
                        "Dreams check {} names an editable path: {argument}",
                        check.name
                    );
                }
            }
            checks.push(CheckSpec {
                name: check.name.clone(),
                argv: check.argv.clone(),
                timeout: Duration::from_secs(check.timeout_seconds.into()),
            });
        }
        let total: u64 = checks.iter().map(|check| check.timeout.as_secs()).sum();
        ensure!(
            total * 1000 + 60_000 <= HOST_TIMEOUT_MS,
            "Dreams check timeouts must total at most {} seconds",
            (HOST_TIMEOUT_MS - 60_000) / 1000
        );

        let digest = hex::encode(Sha256::digest(serde_json::to_vec(&(
            &policy.repository,
            &file.editable,
            hours,
            &file.checks,
        ))?));
        Ok(Self {
            checks,
            digest,
            ..policy
        })
    }

    pub fn editable(&self, path: &str) -> Result<EditablePath, String> {
        let parts = components(path, b"").map_err(|reason| format!("path {path:?} {reason}"))?;
        if self.editable.iter().any(|glob| glob.matches(&parts)) {
            Ok(EditablePath(path.to_owned()))
        } else {
            Err(format!("path {path} is not editable"))
        }
    }

    pub fn refuse_state_inside(&self, state: &Path) -> Result<()> {
        ensure!(
            !resolved(state).starts_with(&self.repository),
            "Dreams repository must not contain the state directory"
        );
        Ok(())
    }

    pub fn repository(&self) -> &Path {
        &self.repository
    }
    pub fn window(&self) -> Duration {
        self.window
    }
    pub fn checks(&self) -> &[CheckSpec] {
        &self.checks
    }
    /// Identifies the repository, editable set, window and checks a review was made under.
    pub fn digest(&self) -> &str {
        &self.digest
    }
}

#[cfg(test)]
mod tests {
    use std::{fs, path::Path};

    use crate::dreams::policy::{DreamsCheckFile, DreamsPolicy, DreamsPolicyFile, ProtectedPaths};

    fn repository(root: &Path) -> std::path::PathBuf {
        let repository = root.join("guidance");
        fs::create_dir_all(repository.join(".git")).unwrap();
        repository
    }

    fn file(repository: &Path) -> DreamsPolicyFile {
        DreamsPolicyFile {
            repository: repository.to_owned(),
            editable: vec!["AGENTS.md".into(), "playbooks/*.md".into()],
            window_hours: None,
            checks: vec![DreamsCheckFile {
                name: "commands-exist".into(),
                argv: vec!["/bin/sh".into(), "/example/checks/commands-exist.sh".into()],
                timeout_seconds: 60,
            }],
        }
    }

    const UNPROTECTED: ProtectedPaths = ProtectedPaths {
        config: None,
        job_directories: &[],
    };

    fn refused(file: &DreamsPolicyFile, protected: &ProtectedPaths) -> String {
        DreamsPolicy::parse(file, protected)
            .unwrap_err()
            .to_string()
    }

    #[test]
    fn editable_paths_match_globs_within_one_component_and_never_git_metadata() {
        let root = tempfile::tempdir().unwrap();
        let mut file = file(&repository(root.path()));
        file.editable.push("*".into());
        file.editable.push("*/*".into());
        let policy = DreamsPolicy::parse(&file, &UNPROTECTED).unwrap();
        for path in [
            "AGENTS.md",
            "playbooks/review.md",
            "README",
            "notes/today.txt",
        ] {
            assert_eq!(policy.editable(path).unwrap().as_str(), path);
        }
        for path in [
            "playbooks/deep/review.md",
            ".git/config",
            ".gitattributes",
            ".GIT/hooks",
            "notes/.gitignore",
            "../AGENTS.md",
            "/etc/passwd",
            "playbooks//review.md",
            "./AGENTS.md",
            "AGENTS.md\n",
            "caf\u{e9}.md",
            "a\\b",
            "say\"hi\".md",
            "all*.md",
            "",
        ] {
            assert!(policy.editable(path).is_err(), "{path:?} must be refused");
        }
        assert_eq!(policy.window().as_secs(), 24 * 60 * 60);
    }

    #[test]
    fn policy_refuses_targets_that_hold_private_paths_and_checks_that_could_be_rewritten() {
        let root = tempfile::tempdir().unwrap();
        let repository = repository(root.path());
        let valid = file(&repository);
        let digest = DreamsPolicy::parse(&valid, &UNPROTECTED)
            .unwrap()
            .digest()
            .to_owned();

        let config = repository.join("config.toml");
        fs::write(&config, "").unwrap();
        assert!(
            refused(
                &valid,
                &ProtectedPaths {
                    config: Some(&config),
                    job_directories: &[]
                }
            )
            .contains("must not contain the configuration file")
        );
        let jobs = [repository.join("jobs")];
        assert!(
            refused(
                &valid,
                &ProtectedPaths {
                    config: None,
                    job_directories: &jobs
                }
            )
            .contains("must not contain a job directory")
        );

        for argument in [
            "AGENTS.md".to_owned(),
            "./playbooks/review.md".to_owned(),
            repository
                .canonicalize()
                .unwrap()
                .join("AGENTS.md")
                .to_string_lossy()
                .into_owned(),
        ] {
            let mut named = valid.clone();
            named.checks[0].argv.push(argument);
            assert!(refused(&named, &UNPROTECTED).contains("names an editable path"));
        }

        let mut changed = valid.clone();
        changed.checks[0].timeout_seconds = 61;
        assert_ne!(
            DreamsPolicy::parse(&changed, &UNPROTECTED)
                .unwrap()
                .digest(),
            digest
        );
        for broken in [
            DreamsPolicyFile {
                editable: vec![],
                ..valid.clone()
            },
            DreamsPolicyFile {
                editable: vec![".git/*".into()],
                ..valid.clone()
            },
            DreamsPolicyFile {
                window_hours: Some(49),
                ..valid.clone()
            },
            DreamsPolicyFile {
                checks: vec![],
                ..valid.clone()
            },
            DreamsPolicyFile {
                checks: vec![valid.checks[0].clone(), valid.checks[0].clone()],
                ..valid.clone()
            },
            DreamsPolicyFile {
                repository: root.path().join("missing"),
                ..valid.clone()
            },
            DreamsPolicyFile {
                repository: root.path().to_owned(),
                ..valid.clone()
            },
        ] {
            assert!(DreamsPolicy::parse(&broken, &UNPROTECTED).is_err());
        }
    }
}
