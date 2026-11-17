//! How Rust runs the runtime's failover scripts: the helper that claims an
//! epoch for a coordinator start, and the operator that the `failover`
//! commands use.

use std::{
    fmt,
    marker::PhantomData,
    path::{Path, PathBuf},
    process::{Command, Output, Stdio},
    time::Duration,
};

use anyhow::{Context, Result, ensure};
use serde::{Serialize, de::DeserializeOwned};

use super::{
    AUTHORITY_UNREACHABLE_EXIT, FailoverReport, FailoverRequest, FailoverSession, OperatorReport,
    OperatorRequest,
};
use crate::runtime::WriterLock;

/// The authority did not answer the helper or the operator. The same request is safe to repeat.
#[derive(Debug)]
pub struct AuthorityUnreachable(String);

impl fmt::Display for AuthorityUnreachable {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for AuthorityUnreachable {}

/// A script under `failover/` beside the runtime script, run once per request
/// with the session in `AGENT_FAILOVER`. It prints one report.
pub struct FailoverScript<Request, Report> {
    path: PathBuf,
    name: &'static str,
    exchange: PhantomData<fn(&Request) -> Report>,
}

pub type FailoverHelper = FailoverScript<FailoverRequest, FailoverReport>;

pub type FailoverOperator = FailoverScript<OperatorRequest, OperatorReport>;

impl FailoverHelper {
    pub fn locate(script: &Path) -> Result<Self> {
        Self::beside(script, "helper.js", "failover helper")
    }
}

impl FailoverOperator {
    pub fn locate(script: &Path) -> Result<Self> {
        Self::beside(script, "operator.js", "failover operator")
    }
}

impl<Request: Serialize, Report: DeserializeOwned> FailoverScript<Request, Report> {
    fn beside(script: &Path, file: &str, name: &'static str) -> Result<Self> {
        let path = script.with_file_name("failover").join(file);
        ensure!(
            path.is_file(),
            "Pi runtime is not built; build the runtime first"
        );
        Ok(Self {
            path,
            name,
            exchange: PhantomData,
        })
    }

    pub fn run(&self, session: &FailoverSession, request: &Request) -> Result<Report> {
        self.finish(self.command(session, request)?)
    }

    /// Runs the script as a holder of `lock`, so the state directory stays
    /// locked while the script still writes to it, also when this process dies.
    pub(crate) fn run_holding(
        &self,
        lock: &WriterLock,
        session: &FailoverSession,
        request: &Request,
    ) -> Result<Report> {
        let mut command = self.command(session, request)?;
        lock.inherit(&mut command);
        self.finish(command)
    }

    /// Runs the script without blocking a runtime thread, and kills it after `limit`.
    pub async fn run_within(
        &self,
        session: &FailoverSession,
        request: &Request,
        limit: Duration,
    ) -> Result<Report> {
        let mut command = tokio::process::Command::from(self.command(session, request)?);
        command.kill_on_drop(true);
        let output = tokio::time::timeout(limit, command.output())
            .await
            .with_context(|| format!("The {} did not answer in time", self.name))?
            .with_context(|| format!("Could not start the {}", self.name))?;
        self.report(output)
    }

    fn finish(&self, mut command: Command) -> Result<Report> {
        let output = command
            .output()
            .with_context(|| format!("Could not start the {}", self.name))?;
        self.report(output)
    }

    fn command(&self, session: &FailoverSession, request: &Request) -> Result<Command> {
        let mut command = Command::new("node");
        command
            .arg("--no-warnings")
            .arg(&self.path)
            .arg(serde_json::to_string(request)?)
            .env("AGENT_FAILOVER", serde_json::to_string(session)?)
            .stdin(Stdio::null());
        Ok(command)
    }

    fn report(&self, output: Output) -> Result<Report> {
        let stderr = String::from_utf8_lossy(&output.stderr);
        if output.status.code() == Some(i32::from(AUTHORITY_UNREACHABLE_EXIT)) {
            return Err(AuthorityUnreachable(stderr.trim().to_owned()).into());
        }
        ensure!(
            output.status.success(),
            "The {} failed ({}): {}",
            self.name,
            output.status,
            stderr.trim()
        );
        serde_json::from_slice(&output.stdout).with_context(|| {
            format!(
                "The {} returned an invalid report: {}",
                self.name,
                stderr.trim()
            )
        })
    }
}
