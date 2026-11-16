//! Every Git and process effect Dreams has. The operator's repository is only
//! read here; candidates live in clones under the private run directory.
use std::{
    fs::{self, OpenOptions},
    io::{self, Write},
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

use anyhow::{Context, Result, bail, ensure};
use tokio::sync::watch;

use crate::{
    dreams::{
        CheckResult, ContentDigest, Revision,
        policy::{CheckSpec, EditablePath},
    },
    host::{ProcessFailure, ProcessOutput, ProcessRequest, run_process_until},
};

const GIT_TIMEOUT: Duration = Duration::from_secs(120);
const GIT_OUTPUT_BYTES: usize = 1024 * 1024;
const CHECK_OUTPUT_BYTES: usize = 16 * 1024;
const LITERAL_PATHS: (&str, &str) = ("GIT_LITERAL_PATHSPECS", "1");

/// Only PATH, HOME, LANG and TMPDIR survive. An inherited GIT_* variable could
/// point Git at another repository, index or configuration, and a check must
/// not see the coordinator's credentials.
fn environment(extra: &[(&str, &str)]) -> Vec<(String, String)> {
    ["PATH", "HOME", "LANG", "TMPDIR"]
        .into_iter()
        .filter_map(|name| Some((name.to_owned(), std::env::var(name).ok()?)))
        .chain(
            extra
                .iter()
                .map(|(name, value)| ((*name).to_owned(), (*value).to_owned())),
        )
        .collect()
}

fn failure(failure: ProcessFailure) -> anyhow::Error {
    match failure {
        ProcessFailure::NotStarted(error) | ProcessFailure::OutcomeUncertain(error) => error,
    }
}

pub struct GitOutput {
    pub exit_code: i32,
    pub stdout: String,
    pub stderr: String,
}

/// Git with fixed arguments, no hooks, no file system monitor and no inherited
/// environment. It never fetches: every repository it touches is local.
pub struct Git {
    directory: PathBuf,
    environment: Vec<(String, String)>,
}

impl Git {
    /// For the operator's repository. Without optional locks a read such as
    /// `status` cannot rewrite the index.
    pub fn reading(directory: &Path) -> Self {
        Self {
            directory: directory.to_owned(),
            environment: environment(&[("GIT_OPTIONAL_LOCKS", "0"), LITERAL_PATHS]),
        }
    }

    pub fn writing(directory: &Path) -> Self {
        Self {
            directory: directory.to_owned(),
            environment: environment(&[LITERAL_PATHS]),
        }
    }

    pub fn with_variable(mut self, name: &str, value: &str) -> Self {
        self.environment.push((name.to_owned(), value.to_owned()));
        self
    }

    pub async fn run(&self, arguments: &[&str]) -> Result<GitOutput> {
        let arguments: Vec<String> = [
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "core.fsmonitor=false",
        ]
        .iter()
        .chain(arguments)
        .map(|argument| (*argument).to_owned())
        .collect();
        let request = ProcessRequest::new(
            "git",
            &arguments,
            &self.directory,
            GIT_TIMEOUT,
            GIT_OUTPUT_BYTES,
        )
        .map_err(failure)?
        .with_only_environment(&self.environment);
        let ProcessOutput {
            exit_code,
            stdout,
            stderr,
            truncated,
        } = run_process_until(request, std::future::pending())
            .await
            .map_err(failure)?;
        ensure!(!truncated, "Git printed more than Dreams reads");
        Ok(GitOutput {
            exit_code,
            stdout,
            stderr,
        })
    }

    /// Standard output of a command that must succeed.
    pub async fn text(&self, arguments: &[&str]) -> Result<String> {
        let output = self.run(arguments).await?;
        ensure!(
            output.exit_code == 0,
            "git {} failed: {}",
            arguments.first().copied().unwrap_or_default(),
            output.stderr.trim()
        );
        Ok(output.stdout)
    }
}

pub(crate) async fn resolve_base(repository: &Path) -> Result<Revision> {
    let head = Git::reading(repository)
        .text(&["rev-parse", "--verify", "--quiet", "HEAD^{commit}"])
        .await
        .context("The Dreams repository has no commit to review")?;
    Revision::parse(head.trim())
}

pub(crate) async fn checkout(repository: &Path, base: &Revision, directory: &Path) -> Result<()> {
    let parent = directory
        .parent()
        .context("A Dreams checkout needs a parent directory")?;
    let (source, destination) = (
        repository
            .to_str()
            .context("Dreams repository path is not UTF-8")?,
        directory
            .to_str()
            .context("Dreams state path is not UTF-8")?,
    );
    Git::reading(parent)
        .text(&[
            "clone",
            "--shared",
            "--no-checkout",
            "--quiet",
            "--",
            source,
            destination,
        ])
        .await?;
    Git::writing(directory)
        .text(&["checkout", "--quiet", "--detach", base.as_str()])
        .await?;
    Ok(())
}

pub(crate) async fn tracked_files(directory: &Path) -> Result<Vec<String>> {
    Ok(Git::writing(directory)
        .text(&["ls-files", "-z"])
        .await?
        .split('\0')
        .filter(|path| !path.is_empty())
        .map(str::to_owned)
        .collect())
}

pub(crate) async fn run_checks(
    directory: &Path,
    checks: &[CheckSpec],
    cancelled: &watch::Receiver<bool>,
) -> Result<Vec<CheckResult>> {
    let environment = environment(&[]);
    let mut results = Vec::new();
    for check in checks {
        let (program, arguments) = check
            .argv
            .split_first()
            .context("A Dreams check has no program")?;
        let mut stop = cancelled.clone();
        let started = Instant::now();
        let finished = match ProcessRequest::new(
            program,
            arguments,
            directory,
            check.timeout,
            CHECK_OUTPUT_BYTES,
        ) {
            Ok(request) => {
                run_process_until(request.with_only_environment(&environment), async move {
                    loop {
                        if *stop.borrow_and_update() {
                            break;
                        }
                        if stop.changed().await.is_err() {
                            std::future::pending::<()>().await;
                        }
                    }
                })
                .await
            }
            Err(error) => Err(error),
        };
        let duration_ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
        let result = |exit_code, timed_out, stdout, stderr, truncated| CheckResult {
            name: check.name.clone(),
            argv: check.argv.clone(),
            exit_code,
            timed_out,
            duration_ms,
            stdout,
            stderr,
            truncated,
        };
        results.push(match finished {
            Ok(output) => {
                if *cancelled.borrow() {
                    bail!("Dreams stopped while check {} was running", check.name);
                }
                let timed_out = output.exit_code == 124 && started.elapsed() >= check.timeout;
                result(
                    (!timed_out).then_some(output.exit_code),
                    timed_out,
                    output.stdout,
                    output.stderr,
                    output.truncated,
                )
            }
            Err(ProcessFailure::NotStarted(error)) => {
                result(None, false, String::new(), format!("{error:#}"), false)
            }
            Err(ProcessFailure::OutcomeUncertain(error)) => return Err(error),
        });
    }
    Ok(results)
}

pub(crate) struct Patch {
    pub digest: ContentDigest,
    pub files: Vec<String>,
}

fn write_edit(candidate: &Path, path: &EditablePath, content: &str) -> Result<Option<String>> {
    let mut current = candidate.to_owned();
    let mut parts: Vec<&str> = path.as_str().split('/').collect();
    let name = parts.pop().context("An editable path has a file name")?;
    for part in parts {
        current.push(part);
        match fs::symlink_metadata(&current) {
            Ok(metadata) if metadata.is_dir() => {}
            Ok(_) => return Ok(Some(format!("{path} has a parent that is not a directory"))),
            Err(error) if error.kind() == io::ErrorKind::NotFound => fs::create_dir(&current)?,
            Err(error) => return Err(error.into()),
        }
    }
    current.push(name);
    match fs::symlink_metadata(&current) {
        Ok(metadata) if !metadata.is_file() => {
            return Ok(Some(format!("{path} is not a regular file")));
        }
        Ok(_) if String::from_utf8(fs::read(&current)?).is_err() => {
            return Ok(Some(format!("{path} is not UTF-8 text")));
        }
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&current)?
        .write_all(content.as_bytes())?;
    Ok(None)
}

pub(crate) async fn write_candidate(
    candidate: &Path,
    base: &Revision,
    edits: &[(EditablePath, &str)],
    patch: &Path,
) -> Result<std::result::Result<Patch, String>> {
    let git = Git::writing(candidate);
    for (path, content) in edits {
        let entry = git
            .text(&["ls-tree", "-z", base.as_str(), "--", path.as_str()])
            .await?;
        let mode = entry.split(' ').next().unwrap_or_default();
        if !matches!(mode, "" | "100644") {
            return Ok(Err(format!(
                "{path} is a symlink, a submodule or an executable at the base"
            )));
        }
        if let Some(reason) = write_edit(candidate, path, content)? {
            return Ok(Err(reason));
        }
    }
    let mut add = vec!["add", "--"];
    add.extend(edits.iter().map(|(path, _)| path.as_str()));
    if git.run(&add).await?.exit_code != 0 {
        return Ok(Err(
            "Git could not stage these paths; an ignored path cannot be proposed".into(),
        ));
    }
    let raw = git
        .text(&[
            "diff",
            "--cached",
            "--raw",
            "-z",
            "--no-renames",
            "--no-abbrev",
            base.as_str(),
        ])
        .await?;
    let mut files = Vec::new();
    let mut fields = raw.split('\0').filter(|field| !field.is_empty());
    while let (Some(change), Some(path)) = (fields.next(), fields.next()) {
        let parts: Vec<&str> = change.split(' ').collect();
        let plain = matches!(
            parts.as_slice(),
            [":100644" | ":000000", "100644", _, _, "M" | "A"]
        );
        ensure!(
            plain && edits.iter().any(|(edited, _)| edited.as_str() == path),
            "A Dreams candidate changed more than the contents of its edited files"
        );
        files.push(path.to_owned());
    }
    if files.is_empty() {
        return Ok(Err("the edits change nothing at the base".into()));
    }
    let output = format!(
        "--output={}",
        patch.to_str().context("Dreams state path is not UTF-8")?
    );
    // Fixed prefixes and context, so the operator's diff settings cannot
    // change the bytes a reviewer approves.
    git.text(&[
        "diff",
        "--cached",
        "--no-ext-diff",
        "--no-textconv",
        "--no-renames",
        "--no-color",
        "--full-index",
        "--src-prefix=a/",
        "--dst-prefix=b/",
        "-U3",
        &output,
        base.as_str(),
    ])
    .await?;
    Ok(Ok(Patch {
        digest: ContentDigest::of(&fs::read(patch)?),
        files,
    }))
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tokio::sync::watch;

    use crate::dreams::{policy::CheckSpec, workspace::run_checks};

    fn check(name: &str, argv: &[&str], seconds: u64) -> CheckSpec {
        CheckSpec {
            name: name.into(),
            argv: argv.iter().map(|argument| (*argument).to_owned()).collect(),
            timeout: Duration::from_secs(seconds),
        }
    }

    #[tokio::test]
    async fn checks_run_in_the_candidate_with_a_cleared_environment_and_a_hard_timeout() {
        let directory = tempfile::tempdir().unwrap();
        let directory = directory.path().canonicalize().unwrap();
        assert!(
            std::env::var_os("CARGO_MANIFEST_DIR").is_some(),
            "The test needs an inherited variable to prove it is not passed on"
        );
        let (_owner, cancelled) = watch::channel(false);
        let results = run_checks(
            &directory,
            &[
                check("environment", &["/bin/sh", "-c", "pwd; env"], 10),
                check("fails", &["/bin/sh", "-c", "echo no; exit 124"], 10),
                check("hangs", &["/bin/sh", "-c", "sleep 30 & wait"], 1),
                check("missing", &["/example/no-such-program"], 10),
            ],
            &cancelled,
        )
        .await
        .unwrap();
        let [environment, fails, hangs, missing] = results.as_slice() else {
            panic!("Every check reports a result");
        };
        assert!(environment.passed());
        assert!(
            environment
                .stdout
                .starts_with(&format!("{}\n", directory.display()))
        );
        assert!(environment.stdout.contains("PATH="));
        assert!(!environment.stdout.contains("CARGO_MANIFEST_DIR"));
        assert_eq!((fails.exit_code, fails.timed_out), (Some(124), false));
        assert!(!fails.passed());
        assert_eq!((hangs.exit_code, hangs.timed_out), (None, true));
        assert_eq!(hangs.verdict(), "timed out");
        assert_eq!(missing.verdict(), "did not start");
        assert!(!missing.passed());

        let (owner, cancelled) = watch::channel(false);
        owner.send(true).unwrap();
        let stopped = run_checks(
            &directory,
            &[check("hangs", &["/bin/sh", "-c", "sleep 30"], 20)],
            &cancelled,
        )
        .await;
        assert!(stopped.unwrap_err().to_string().contains("Dreams stopped"));
    }
}
