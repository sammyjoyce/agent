mod coordinator;
mod gate;
mod provider;
mod report;
mod resources;
mod scenario;
mod session;
mod terminal;

use std::{
    collections::BTreeMap, fs, io::Write, os::unix::fs::PermissionsExt, path::PathBuf,
    time::Duration,
};

use anyhow::{Context as _, Result, anyhow, ensure};
use clap::{Parser, ValueEnum};
use serde::{Deserialize, Serialize};
use tokio::{process::Command, time::timeout};

use coordinator::{Coordinator, Receipts, isolated};
use gate::Version;
use report::Sample;
use scenario::{Lifetime, Scenario};
use session::Context;

const DEADLINE: Duration = Duration::from_secs(20);

#[derive(Parser)]
#[command(about = "Measure the real CLI's application delay against a paired baseline")]
struct Arguments {
    #[arg(long)]
    baseline: PathBuf,
    #[arg(long)]
    baseline_runtime: PathBuf,
    #[arg(long)]
    candidate: PathBuf,
    #[arg(long)]
    candidate_runtime: PathBuf,
    #[arg(long)]
    terminal: PathBuf,
    /// Compiled runtime/test/fixtures/performance.js.
    #[arg(long)]
    seed: PathBuf,
    /// Compiled runtime/test/fixtures/performance-runtime.js. It starts each
    /// version's runtime against the loopback model provider.
    #[arg(long)]
    runtime_shim: PathBuf,
    #[arg(long, default_value_t = 7, value_parser = clap::value_parser!(u8).range(3..=31))]
    samples: u8,
    /// Run only these scenarios; repeat the flag for several. Defaults to all.
    #[arg(long = "scenario", value_enum)]
    scenarios: Vec<Scenario>,
    #[arg(long, default_value = "performance/results.json")]
    output: PathBuf,
}

#[derive(Deserialize)]
struct Seed {
    chief: String,
    long_history: String,
}

struct Versions {
    baseline: (PathBuf, PathBuf),
    candidate: (PathBuf, PathBuf),
}

impl Versions {
    fn of(&self, version: Version) -> (&PathBuf, &PathBuf) {
        let (binary, runtime) = match version {
            Version::Baseline => &self.baseline,
            Version::Candidate => &self.candidate,
        };
        (binary, runtime)
    }
}

async fn run(mut options: Arguments) -> Result<()> {
    if let Some(parent) = options.output.parent() {
        fs::create_dir_all(parent)?;
    }
    for previous in [
        &options.output,
        &options.output.with_extension("failure.json"),
    ] {
        match fs::remove_file(previous) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
    }
    let mut raw = fs::File::create(options.output.with_extension("jsonl"))?;
    for path in [
        &mut options.baseline,
        &mut options.baseline_runtime,
        &mut options.candidate,
        &mut options.candidate_runtime,
        &mut options.terminal,
        &mut options.seed,
        &mut options.runtime_shim,
    ] {
        *path = fs::canonicalize(&*path)
            .with_context(|| format!("Could not locate {}", path.display()))?;
    }
    let mut scenarios = if options.scenarios.is_empty() {
        Scenario::value_variants().to_vec()
    } else {
        options.scenarios.clone()
    };
    scenarios.sort();
    scenarios.dedup();
    let versions = Versions {
        baseline: (options.baseline.clone(), options.baseline_runtime.clone()),
        candidate: (options.candidate.clone(), options.candidate_runtime.clone()),
    };
    let snapshot = tempfile::tempdir()?;
    fs::set_permissions(snapshot.path(), fs::Permissions::from_mode(0o700))?;
    let mut command = Command::new("node");
    command.arg(&options.seed).arg(snapshot.path());
    isolated(&mut command, snapshot.path())?;
    let seeded = timeout(Duration::from_secs(60), command.output())
        .await
        .context("Synthetic history seeding did not finish")??;
    ensure!(
        seeded.status.success(),
        "Could not seed native history: {}",
        String::from_utf8_lossy(&seeded.stderr)
    );
    let seed: Seed = serde_json::from_slice(&seeded.stdout)?;
    ensure!(
        !seed.chief.is_empty(),
        "The native chief conversation is missing"
    );
    let start = async |version| {
        let (binary, runtime) = versions.of(version);
        Coordinator::start(binary, &options.runtime_shim, runtime, snapshot.path(), &[]).await
    };
    let mut shared = BTreeMap::new();
    if scenarios
        .iter()
        .any(|scenario| scenario.definition().coordinator == Lifetime::SharedPerVersion)
    {
        for version in [Version::Baseline, Version::Candidate] {
            match start(version).await {
                Ok(coordinator) => {
                    shared.insert(version, coordinator);
                }
                Err(error) => {
                    for (_, coordinator) in shared {
                        if let Err(cleanup) = Coordinator::close(coordinator).await {
                            return Err(error.context(format!("Cleanup failed: {cleanup:#}")));
                        }
                    }
                    return Err(error);
                }
            }
        }
    }
    let measured = async {
        let mut samples = Vec::new();
        for scenario in &scenarios {
            let definition = scenario.definition();
            for pair in 0..=options.samples {
                let order = if pair % 2 == 0 {
                    [Version::Baseline, Version::Candidate]
                } else {
                    [Version::Candidate, Version::Baseline]
                };
                for version in order {
                    let (binary, runtime) = versions.of(version);
                    let owned = match definition.coordinator {
                        Lifetime::PerSample => Some(
                            Coordinator::start(
                                binary,
                                &options.runtime_shim,
                                runtime,
                                snapshot.path(),
                                definition.turns,
                            )
                            .await?,
                        ),
                        Lifetime::SharedPerVersion => None,
                    };
                    let coordinator = owned
                        .as_ref()
                        .or(shared.get(&version))
                        .context("The shared coordinator is missing")?;
                    let outcome = scenario::drive(
                        *scenario,
                        &Context {
                            terminal: &options.terminal,
                            binary,
                            runtime,
                            coordinator,
                            seed: &seed,
                        },
                    )
                    .await;
                    let (requests, receipts, closed) = match owned {
                        Some(owned) => match owned.close().await {
                            Ok(closed) => (closed.requests, closed.receipts, Ok(())),
                            Err(error) => (Vec::new(), Receipts::default(), Err(error)),
                        },
                        None => (coordinator.requests()?, Receipts::default(), Ok(())),
                    };
                    let outcome = outcome?;
                    closed?;
                    scenario::verify(*scenario, &outcome, &requests).map_err(|error| {
                        anyhow!(
                            "{scenario:?} {version:?} pair {pair}: {error:#}\nmarks: {:?}\nprovider requests: {requests:?}\nvisible screen:\n{}",
                            outcome.marks,
                            outcome.screen
                        )
                    })?;
                    let sample = Sample::new((*scenario, version, pair), outcome, &requests, receipts)?;
                    serde_json::to_writer(&mut raw, &sample)?;
                    raw.write_all(b"\n")?;
                    raw.flush()?;
                    samples.push(sample);
                }
            }
        }
        Ok::<_, anyhow::Error>(samples)
    }
    .await;
    let mut closed = Vec::new();
    for (version, coordinator) in shared {
        closed.push(coordinator.close().await.and_then(|closed| {
            ensure!(
                closed.requests.is_empty(),
                "The {version:?} launch coordinator contacted the provider: {:?}",
                closed.requests
            );
            Ok(())
        }));
    }
    let samples = measured?;
    closed.into_iter().collect::<Result<Vec<_>>>()?;
    let report = report::build(&scenarios, samples)?;
    fs::write(&options.output, serde_json::to_vec_pretty(&report)?)?;
    report::print(&report);
    ensure!(
        report.passed(),
        "CLI responsiveness regressed; raw samples are in {}",
        options.output.display()
    );
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let options = Arguments::parse();
    let failure = options.output.with_extension("failure.json");
    let result = run(options).await;
    if let Err(error) = &result {
        #[derive(Serialize)]
        struct Failure {
            error: String,
        }
        fs::write(
            failure,
            serde_json::to_vec_pretty(&Failure {
                error: format!("{error:#}"),
            })?,
        )?;
    }
    result
}
