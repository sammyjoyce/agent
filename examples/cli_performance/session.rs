//! How one sample's CLI session runs: a measured launch, or an interactive
//! session prepared outside timing around a scenario's measured steps.

use std::{
    path::Path,
    time::{Duration, Instant, SystemTime},
};

use anyhow::{Result, anyhow, ensure};
use tokio::{process::Command, time::sleep};

use crate::{
    Seed,
    coordinator::{Coordinator, Tokens, isolated, read_pid},
    gate::{Mark, Marks},
    resources::{Process, Role, Window},
    scenario::{CHIEF_SENTENCE, ENTER, PRIME, PRIME_ANSWER},
    terminal::{Sight, Terminal},
};

const QUIET: Duration = Duration::from_secs(1);

pub struct Context<'a> {
    pub terminal: &'a Path,
    pub binary: &'a Path,
    pub runtime: &'a Path,
    pub coordinator: &'a Coordinator,
    pub seed: &'a Seed,
}

pub struct Outcome {
    pub origin: Instant,
    /// The resource window's open, on both clocks, for mapping epoch receipts.
    pub opened: (SystemTime, Instant),
    pub marks: Marks,
    pub processes: Vec<Process>,
    pub tokens: Option<Tokens>,
    pub screen: String,
    pub received_bytes: usize,
}

fn cli(context: &Context<'_>, pid_file: &Path, resume: Option<String>) -> Result<Command> {
    let directory = context.coordinator.directory();
    let mut command = Command::new(context.terminal);
    command
        .arg(context.binary)
        .arg("--state-dir")
        .arg(directory)
        .arg("--config")
        .arg(directory.join("config.toml"))
        .arg("--instructions")
        .arg(directory.join("AGENTS.md"))
        .arg("--runtime")
        .arg(context.runtime)
        .arg("chat")
        .args(resume);
    isolated(&mut command, directory)?;
    command.env("AGENT_TEST_TERMINAL_PID", pid_file);
    Ok(command)
}

pub async fn launch(
    context: &Context<'_>,
    resume: Option<String>,
    sentence: &'static str,
) -> Result<Outcome> {
    let pids = tempfile::tempdir()?;
    let pid_file = pids.path().join("cli.pid");
    let command = cli(context, &pid_file, resume)?;
    let services = [
        (Role::Coordinator, context.coordinator.pid()?),
        (Role::Runtime, context.coordinator.runtime_pid()?),
    ];
    let window = Window::open(&services)?;
    let opened = (SystemTime::now(), Instant::now());
    let (spawned, terminal, mut seen) = Terminal::spawn(command, vec![Sight::Shows(sentence)])?;
    let mut marks = Marks::default();
    marks.record(Mark::Spawn, spawned)?;
    let measured = async {
        marks.record(Mark::StoredTextVisible, seen.next().await?)?;
        let [coordinator, runtime] = services;
        window.close(&[(Role::Cli, read_pid(&pid_file)?), coordinator, runtime])
    }
    .await;
    match measured {
        Ok(processes) => Ok(Outcome {
            origin: spawned,
            opened,
            screen: terminal.contents(),
            marks,
            processes,
            tokens: None,
            received_bytes: terminal.exit().await?,
        }),
        Err(error) => Err(evidence(error, terminal, &marks, context.coordinator).await),
    }
}

/// Outside timing, the chief becomes visible and a first turn settles, so the
/// measured steps start from a warm, idle conversation.
pub async fn interactive(
    context: &Context<'_>,
    steps: impl AsyncFnOnce(&Terminal, &mut Marks) -> Result<()>,
) -> Result<Outcome> {
    let pids = tempfile::tempdir()?;
    let pid_file = pids.path().join("cli.pid");
    let coordinator = context.coordinator;
    let (origin, terminal, mut seen) = Terminal::spawn(
        cli(context, &pid_file, None)?,
        vec![Sight::Shows(CHIEF_SENTENCE)],
    )?;
    let mut marks = Marks::default();
    let measured = async {
        seen.next().await?;
        terminal.compose(PRIME.prompt).await?;
        terminal
            .press(ENTER, vec![Sight::Settled(PRIME_ANSWER)])
            .await?
            .1
            .next()
            .await?;
        let before = coordinator.ledger(&context.seed.chief).await?;
        let roles = || -> Result<[(Role, i32); 3]> {
            Ok([
                (Role::Cli, read_pid(&pid_file)?),
                (Role::Coordinator, coordinator.pid()?),
                (Role::Runtime, coordinator.runtime_pid()?),
            ])
        };
        let window = Window::open(&roles()?)?;
        let opened = (SystemTime::now(), Instant::now());
        steps(&terminal, &mut marks).await?;
        let processes = window.close(&roles()?)?;
        if let Ok(esc) = marks.get(Mark::Esc) {
            sleep(QUIET).await;
            ensure!(
                coordinator
                    .requests()?
                    .iter()
                    .all(|request| request.received < esc),
                "A provider request arrived after Esc"
            );
        }
        let tokens = coordinator
            .ledger(&context.seed.chief)
            .await?
            .since(before)?;
        Ok((opened, processes, tokens))
    }
    .await;
    match measured {
        Ok((opened, processes, tokens)) => Ok(Outcome {
            origin,
            opened,
            screen: terminal.contents(),
            marks,
            processes,
            tokens: Some(tokens),
            received_bytes: terminal.exit().await?,
        }),
        Err(error) => Err(evidence(error, terminal, &marks, coordinator).await),
    }
}

async fn evidence(
    error: anyhow::Error,
    terminal: Terminal,
    marks: &Marks,
    coordinator: &Coordinator,
) -> anyhow::Error {
    let screen = terminal.contents();
    let stderr = terminal.kill().await;
    anyhow!(
        "{error:#}\nmarks: {marks:?}\nprovider requests: {:?}\nterminal stderr: {stderr}\nvisible screen:\n{screen}",
        coordinator.requests()
    )
}
