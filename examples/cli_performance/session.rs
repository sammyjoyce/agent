use std::{
    path::Path,
    time::{Duration, Instant, SystemTime},
};

use anyhow::{Result, anyhow, ensure};
use tokio::{process::Command, time::sleep};

use crate::{
    Seed,
    background::Evidence,
    coordinator::{Coordinator, Tokens, isolated, read_pid},
    gate::{Mark, Marks},
    load::Load,
    resources::{Process, Role, Window},
    scenario::{CHIEF_SENTENCE, ENTER, PRIME, PRIME_ANSWER},
    terminal::{Sight, Terminal},
};

const QUIET: Duration = Duration::from_secs(1);
const SILENCE_AFTER_LAST_FRAME: Duration = Duration::from_millis(500);

pub struct Context<'a> {
    pub terminal: &'a Path,
    pub binary: &'a Path,
    pub runtime: &'a Path,
    pub coordinator: &'a Coordinator,
    pub seed: &'a Seed,
}

#[derive(Clone, Copy)]
pub struct Anchor {
    pub wall: SystemTime,
    pub monotonic: Instant,
}

impl Anchor {
    fn now() -> Self {
        Self {
            wall: SystemTime::now(),
            monotonic: Instant::now(),
        }
    }
}

pub struct Outcome {
    pub origin: Instant,
    pub opened: Anchor,
    pub marks: Marks,
    pub processes: Vec<Process>,
    pub tokens: Option<Tokens>,
    pub background: Evidence,
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

fn services(context: &Context<'_>, pid_file: &Path) -> Result<[(Role, i32); 3]> {
    Ok([
        (Role::Cli, read_pid(pid_file)?),
        (Role::Coordinator, context.coordinator.pid()?),
        (Role::Runtime, context.coordinator.runtime_pid()?),
    ])
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
    let opened = Anchor::now();
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
            background: Evidence::None,
            received_bytes: terminal.exit().await?,
        }),
        Err(error) => Err(evidence(error, terminal, &marks, context.coordinator, None).await),
    }
}

pub async fn browse(
    context: &Context<'_>,
    resume: String,
    sentence: &'static str,
    steps: impl AsyncFnOnce(&Terminal, &mut Marks) -> Result<()>,
) -> Result<Outcome> {
    let pids = tempfile::tempdir()?;
    let pid_file = pids.path().join("cli.pid");
    let (origin, terminal, mut seen) = Terminal::spawn(
        cli(context, &pid_file, Some(resume))?,
        vec![Sight::Shows(sentence), Sight::ReplayFinished(sentence)],
    )?;
    let mut marks = Marks::default();
    marks.record(Mark::Spawn, origin)?;
    let measured = async {
        marks.record(Mark::StoredTextVisible, seen.next().await?)?;
        marks.record(Mark::ReplayFinished, seen.next().await?)?;
        marks.record(
            Mark::OutputSettled,
            terminal
                .last_output_before_quiet(SILENCE_AFTER_LAST_FRAME)
                .await?,
        )?;
        let window = Window::open(&services(context, &pid_file)?)?;
        let opened = Anchor::now();
        steps(&terminal, &mut marks).await?;
        Ok((opened, window.close(&services(context, &pid_file)?)?))
    }
    .await;
    match measured {
        Ok((opened, processes)) => Ok(Outcome {
            origin,
            opened,
            screen: terminal.contents(),
            marks,
            processes,
            tokens: None,
            background: Evidence::None,
            received_bytes: terminal.exit().await?,
        }),
        Err(error) => Err(evidence(error, terminal, &marks, context.coordinator, None).await),
    }
}

pub async fn interactive(
    context: &Context<'_>,
    steps: impl AsyncFnOnce(&Terminal, &mut Marks, &mut Load) -> Result<()>,
) -> Result<Outcome> {
    let pids = tempfile::tempdir()?;
    let pid_file = pids.path().join("cli.pid");
    let coordinator = context.coordinator;
    let (origin, terminal, mut seen) = Terminal::spawn(
        cli(context, &pid_file, None)?,
        vec![Sight::Shows(CHIEF_SENTENCE)],
    )?;
    let mut marks = Marks::default();
    let mut load = Load::None;
    let measured = async {
        seen.next().await?;
        terminal.compose(PRIME.prompt).await?;
        terminal
            .press(ENTER, vec![Sight::Settled(PRIME_ANSWER)])
            .await?
            .sightings
            .next()
            .await?;
        let before = coordinator.ledger(&context.seed.chief).await?;
        load = Load::start(coordinator, &context.seed.long_history).await?;
        let roles = |load: &Load| -> Result<Vec<(Role, i32)>> {
            let mut roles = services(context, &pid_file)?.to_vec();
            roles.extend(load.process()?);
            Ok(roles)
        };
        let window = Window::open(&roles(&load)?)?;
        let opened = Anchor::now();
        steps(&terminal, &mut marks, &mut load).await?;
        let processes = window.close(&roles(&load)?)?;
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
    let background = load.finish().await;
    match (measured, background) {
        (Ok((opened, processes, tokens)), Ok(background)) => Ok(Outcome {
            origin,
            opened,
            screen: terminal.contents(),
            marks,
            processes,
            tokens: Some(tokens),
            background,
            received_bytes: terminal.exit().await?,
        }),
        (Ok(_), Err(error)) => Err(evidence(error, terminal, &marks, coordinator, None).await),
        (Err(error), background) => {
            Err(evidence(error, terminal, &marks, coordinator, Some(background)).await)
        }
    }
}

async fn evidence(
    error: anyhow::Error,
    terminal: Terminal,
    marks: &Marks,
    coordinator: &Coordinator,
    background: Option<Result<Evidence>>,
) -> anyhow::Error {
    let screen = terminal.contents();
    let stderr = terminal.kill().await;
    anyhow!(
        "{error:#}\nmarks: {marks:?}\nprovider requests: {:?}\nbackground: {background:?}\nterminal stderr: {stderr}\nvisible screen:\n{screen}",
        coordinator.requests()
    )
}
