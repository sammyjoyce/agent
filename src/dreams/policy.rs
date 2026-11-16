use std::{
    collections::BTreeSet,
    path::{Component, Path, PathBuf},
    time::Duration,
};

use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};

use crate::dreams::{HOST_TIMEOUT_MS, MAX_PATH_BYTES, MAX_WINDOW_HOURS, PolicyDigest};

const DEFAULT_WINDOW_HOURS: u8 = 24;
const MAX_CHECK_SECONDS: u16 = 600;

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
    digest: PolicyDigest,
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

fn canonicalize_existing_ancestor(path: &Path) -> PathBuf {
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
    fn matches_ignoring_case(&self, lowered: &[String]) -> bool {
        self.0.len() == lowered.len()
            && self
                .0
                .iter()
                .zip(lowered)
                .all(|(pattern, part)| wildcard(pattern.to_lowercase().as_bytes(), part.as_bytes()))
    }
}

fn editable_in(globs: &[Glob], path: &str) -> Result<EditablePath, String> {
    let parts = components(path, b"").map_err(|reason| format!("path {path:?} {reason}"))?;
    if globs.iter().any(|glob| glob.matches(&parts)) {
        Ok(EditablePath(path.to_owned()))
    } else {
        Err(format!("path {path} is not editable"))
    }
}

fn normalize_lexically(path: &Path) -> PathBuf {
    let mut normal = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                normal.pop();
            }
            other => normal.push(other),
        }
    }
    normal
}

/// A `..` after a symlink lands somewhere its spelling does not say, and a
/// relative `..` can leave the clone a check runs in.
fn climbs_past_what_was_followed(written: &Path, lands_in_tree: bool) -> bool {
    written
        .components()
        .any(|part| part == Component::ParentDir)
        && (written.is_relative() || lands_in_tree)
}

/// The argument itself, and the value of each `name=value` form in it.
fn path_candidates(argument: &str) -> impl Iterator<Item = &str> {
    std::iter::once(argument).chain(
        argument
            .match_indices('=')
            .map(|(index, _)| &argument[index + 1..]),
    )
}

/// Refuses a check argument that names an editable path in `tree`, which is
/// the repository or a clone of it that the check is about to run in.
///
/// Each candidate is followed both by name and through the file system, which
/// resolves symlinks and, on a volume that folds case, the stored spelling.
/// Names are compared without case, so a file that does not exist yet is
/// covered on such a volume too. A volume can also fold other Unicode
/// characters into ASCII. Editable paths are ASCII, so a candidate inside the
/// tree must be ASCII as well.
fn refuse_editable_argument(
    tree: &Path,
    editable: &[Glob],
    check: &str,
    argument: &str,
) -> Result<()> {
    for candidate in path_candidates(argument) {
        let written = Path::new(candidate);
        let anchored = tree.join(written);
        let landings: Vec<PathBuf> = [
            normalize_lexically(&anchored),
            normalize_lexically(&canonicalize_existing_ancestor(&anchored)),
        ]
        .into_iter()
        .filter_map(|landing| Some(landing.strip_prefix(tree).ok()?.to_owned()))
        .collect();
        let names_editable = landings.iter().any(|relative| {
            let parts: Vec<String> = relative
                .components()
                .map(|part| part.as_os_str().to_string_lossy().to_lowercase())
                .collect();
            !parts.is_empty()
                && editable
                    .iter()
                    .any(|glob| glob.matches_ignoring_case(&parts))
        });
        if names_editable {
            bail!("Dreams check {check} names an editable path: {argument}");
        }
        if !landings.is_empty() && !candidate.is_ascii() {
            bail!(
                "Dreams check {check} has a non-ASCII argument inside the repository, which a volume may fold into an editable path: {argument}. Use ASCII, or an absolute path outside the repository"
            );
        }
        if climbs_past_what_was_followed(written, !landings.is_empty()) {
            bail!(
                "Dreams check {check} reaches a path through `..`: {argument}. Write the path without `..`"
            );
        }
    }
    Ok(())
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
        let inside = |path: &Path| canonicalize_existing_ancestor(path).starts_with(&repository);
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
                refuse_editable_argument(&repository, &editable, &check.name, argument)?;
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

        let digest = PolicyDigest::of(&serde_json::to_vec(&(
            &repository,
            &file.editable,
            hours,
            &file.checks,
        ))?);
        Ok(Self {
            repository,
            editable,
            window: Duration::from_secs(u64::from(hours) * 60 * 60),
            checks,
            digest,
        })
    }

    pub fn editable(&self, path: &str) -> Result<EditablePath, String> {
        editable_in(&self.editable, path)
    }

    /// The guard that ran when the policy was loaded, run again where the
    /// checks are about to run. The repository changes after the load: a commit
    /// can turn a harmless argument into a symlink to an editable file.
    pub(crate) fn refuse_editable_check_arguments(&self, clone: &Path) -> Result<()> {
        let clone = clone
            .canonicalize()
            .context("The clone for the Dreams checks is unavailable")?;
        for tree in [self.repository.as_path(), clone.as_path()] {
            for check in &self.checks {
                for argument in &check.argv {
                    refuse_editable_argument(tree, &self.editable, &check.name, argument)?;
                }
            }
        }
        Ok(())
    }

    pub fn refuse_state_inside(&self, state: &Path) -> Result<()> {
        ensure!(
            !canonicalize_existing_ancestor(state).starts_with(&self.repository),
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
    pub fn digest(&self) -> &PolicyDigest {
        &self.digest
    }
}

#[cfg(test)]
mod tests {
    use std::{fs, os::unix::fs::symlink, path::Path};

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
            .clone();

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
            &digest
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

    #[test]
    fn a_check_argument_is_refused_under_every_spelling_that_reaches_an_editable_file() {
        let root = tempfile::tempdir().unwrap();
        let repository = repository(root.path());
        fs::write(repository.join("AGENTS.md"), "Example guidance.\n").unwrap();
        fs::write(repository.join("Makefile"), "test:\n").unwrap();
        fs::create_dir(repository.join("playbooks")).unwrap();
        fs::write(
            repository.join("playbooks/review.md"),
            "Example playbook.\n",
        )
        .unwrap();
        symlink("AGENTS.md", repository.join("alias.txt")).unwrap();
        symlink("playbooks", repository.join("linked")).unwrap();
        symlink(&repository, root.path().join("elsewhere")).unwrap();
        let canonical = repository.canonicalize().unwrap();
        let under =
            |base: &Path, relative: &str| base.join(relative).to_string_lossy().into_owned();
        let valid = file(&repository);
        let parsed = |argument: &str| {
            let mut policy = valid.clone();
            policy.checks[0].argv.push(argument.to_owned());
            DreamsPolicy::parse(&policy, &UNPROTECTED)
        };

        let accepted: Vec<String> = [
            "AGENTS.md".to_owned(),
            "./AGENTS.md".into(),
            ".//AGENTS.md".into(),
            "AGENTS.md/".into(),
            "playbooks//review.md".into(),
            "playbooks/../AGENTS.md".into(),
            "nested/../AGENTS.md".into(),
            "../guidance/AGENTS.md".into(),
            "scripts/../Makefile".into(),
            "agents.md".into(),
            "PLAYBOOKS/Review.MD".into(),
            "Playbooks/new.md".into(),
            "alias.txt".into(),
            "linked/review.md".into(),
            under(&canonical, "AGENTS.md"),
            under(&canonical, "playbooks/../AGENTS.md"),
            under(&canonical, "scripts/../Makefile"),
            under(root.path(), "guidance/AGENTS.md"),
            under(root.path(), "elsewhere/AGENTS.md"),
            under(root.path(), "elsewhere/linked/review.md"),
        ]
        .into_iter()
        .filter(|argument| parsed(argument).is_ok())
        .collect();
        assert!(
            accepted.is_empty(),
            "The policy accepted check arguments that reach an editable file: {accepted:?}"
        );
        assert!(
            parsed(".//AGENTS.md")
                .unwrap_err()
                .to_string()
                .contains("names an editable path")
        );

        for argument in [
            "-c".to_owned(),
            "exit 0".into(),
            "--range=1..3".into(),
            "Makefile".into(),
            "README.md".into(),
            under(&canonical, "Makefile"),
            under(root.path(), "checks/commands-exist.sh"),
        ] {
            assert!(
                parsed(&argument).is_ok(),
                "{argument:?} names no editable file and must stay allowed"
            );
        }
    }

    fn with_argument(repository: &Path, argument: &str) -> anyhow::Result<DreamsPolicy> {
        let mut policy = file(repository);
        policy.checks[0].argv.push(argument.to_owned());
        DreamsPolicy::parse(&policy, &UNPROTECTED)
    }

    #[test]
    fn a_check_argument_that_a_unicode_folding_volume_reads_as_an_editable_path_is_refused() {
        let root = tempfile::tempdir().unwrap();
        let repository = repository(root.path());
        fs::write(repository.join("AGENTS.md"), "Example guidance.\n").unwrap();
        let accepted: Vec<&str> = [
            "AGENT\u{17f}.md",
            "playbook\u{17f}/new.md",
            "PLAYBOOK\u{17f}/New.md",
            "playbooks/\u{212a}eep.md",
        ]
        .into_iter()
        .filter(|argument| with_argument(&repository, argument).is_ok())
        .collect();
        assert!(
            accepted.is_empty(),
            "The policy accepted arguments that fold to an editable path: {accepted:?}"
        );
        assert!(
            with_argument(&repository, "playbook\u{17f}/new.md")
                .unwrap_err()
                .to_string()
                .contains("non-ASCII argument")
        );
        let outside = root.path().join("checks/caf\u{e9}.sh");
        assert!(
            with_argument(&repository, outside.to_str().unwrap()).is_ok(),
            "An absolute path outside the repository may use any characters"
        );
    }

    #[test]
    fn an_option_value_that_names_an_editable_path_is_refused() {
        let root = tempfile::tempdir().unwrap();
        let repository = repository(root.path());
        fs::create_dir(repository.join("playbooks")).unwrap();
        fs::write(repository.join("playbooks/patterns.md"), "^before$\n").unwrap();
        let inside = repository.canonicalize().unwrap().join("AGENTS.md");
        let accepted: Vec<String> = [
            "--file=playbooks/patterns.md".to_owned(),
            "--file=./AGENTS.md".into(),
            "PATTERNS=agents.md".into(),
            "--first=x=AGENTS.md".into(),
            format!("--file={}", inside.display()),
        ]
        .into_iter()
        .filter(|argument| with_argument(&repository, argument).is_ok())
        .collect();
        assert!(
            accepted.is_empty(),
            "The policy accepted option values that name an editable path: {accepted:?}"
        );
        for argument in [
            "--range=1..3",
            "--color=never",
            "LANG=C",
            "--file=Makefile",
            "=",
        ] {
            assert!(
                with_argument(&repository, argument).is_ok(),
                "{argument:?} names no editable file and must stay allowed"
            );
        }
    }
}
