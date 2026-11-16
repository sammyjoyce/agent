//! Every Git and process effect Dreams has. The operator's repository is only
//! read here; candidates live in clones under the private run directory.
use std::{
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

use anyhow::{Context, Result, bail, ensure};
use tokio::sync::watch;

use crate::{
    dreams::{CheckResult, Revision, policy::CheckSpec},
    host::{ProcessFailure, ProcessOutput, ProcessRequest, run_process_until},
};

const GIT_TIMEOUT: Duration = Duration::from_secs(120);
const GIT_OUTPUT_BYTES: usize = 1024 * 1024;
const CHECK_OUTPUT_BYTES: usize = 16 * 1024;

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
            environment: environment(&[("GIT_OPTIONAL_LOCKS", "0")]),
        }
    }

    /// For a clone this process owns, and for the apply command's target.
    pub fn writing(directory: &Path) -> Self {
        Self {
            directory: directory.to_owned(),
            environment: environment(&[]),
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

/// A private clone detached at `base`. It shares the target's objects and
/// writes nothing to the target.
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

/// Runs the policy's commands in `directory`, one at a time. Nothing in a
/// Dreams request can choose a program, an argument or the directory's name.
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
                // The runner reports its own timeout as 124; a check that
                // exits 124 before the deadline is an ordinary failure.
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
