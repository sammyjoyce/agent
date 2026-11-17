use std::{
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use anyhow::{Context as _, Result, anyhow, bail};
use serde::Deserialize;
use serde_json::json;
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    sync::watch,
    task::JoinSet,
    time::{sleep, timeout},
};

use crate::{
    DEADLINE,
    background::{Background, Evidence, ImportPhase, ImportProgress, SearchRequest},
    coordinator::{Coordinator, read_pid},
    resources::Role,
};

const SEARCH_LOOPS_FOR_CONTINUOUS_OVERLAP: usize = 4;
pub const SEARCH_QUERY: &str = "previous task context remains readable";
const SEARCH_LIMIT: u32 = 8;

type Log<T> = Arc<Mutex<Vec<T>>>;

fn snapshot<T: Clone>(log: &Log<T>) -> Result<Vec<T>> {
    Ok(log
        .lock()
        .map_err(|_| anyhow!("The background evidence is unavailable"))?
        .clone())
}

fn push<T>(log: &Log<T>, value: T) -> Result<()> {
    log.lock()
        .map_err(|_| anyhow!("The background evidence is unavailable"))?
        .push(value);
    Ok(())
}

pub enum Load {
    None,
    Search {
        stop: watch::Sender<bool>,
        loops: JoinSet<Result<()>>,
        log: Log<SearchRequest>,
    },
    Import {
        reader: JoinSet<Result<()>>,
        log: Log<ImportProgress>,
        pid_file: PathBuf,
    },
}

impl Load {
    pub async fn start(coordinator: &Coordinator, expected: &str) -> Result<Self> {
        let background = coordinator.background();
        let directory = coordinator.directory().to_path_buf();
        let mut load = match background {
            Background::None => return Ok(Self::None),
            Background::Search => {
                let (stop, stopped) = watch::channel(false);
                let log = Log::default();
                let mut loops = JoinSet::new();
                for _ in 0..SEARCH_LOOPS_FOR_CONTINUOUS_OVERLAP {
                    let (directory, expected, stopped, log) = (
                        directory.clone(),
                        expected.to_owned(),
                        stopped.clone(),
                        log.clone(),
                    );
                    loops.spawn(async move {
                        while !*stopped.borrow() {
                            push(&log, search(&directory, &expected).await?)?;
                        }
                        Ok(())
                    });
                }
                Self::Search { stop, loops, log }
            }
            Background::Import => {
                let log = Log::default();
                let mut reader = JoinSet::new();
                reader.spawn(import_from_every_registered_node(directory, log.clone()));
                Self::Import {
                    reader,
                    log,
                    pid_file: coordinator.codex_pid_file(),
                }
            }
        };
        let started = timeout(DEADLINE, async {
            loop {
                match &mut load {
                    Self::None => return Ok(()),
                    Self::Search { loops, log, .. } => {
                        if snapshot(log)?.iter().any(|request| request.expected_found) {
                            return Ok(());
                        }
                        if let Some(ended) = loops.try_join_next() {
                            ended??;
                            bail!("A search loop stopped before the window");
                        }
                    }
                    Self::Import { reader, log, .. } => {
                        if snapshot(log)?.iter().any(|event| {
                            event.phase == ImportPhase::Importing && event.items_added > 0
                        }) {
                            return Ok(());
                        }
                        if let Some(ended) = reader.try_join_next() {
                            ended??;
                            bail!(
                                "The import ended before it committed an item: {:?}",
                                snapshot(log)?
                            );
                        }
                    }
                }
                sleep(Duration::from_millis(5)).await;
            }
        })
        .await;
        match started {
            Ok(Ok(())) => Ok(load),
            Ok(Err(error)) => Err(error),
            Err(_) => Err(anyhow!(
                "The {background:?} load did not start: {:?}",
                load.finish().await
            )),
        }
    }

    pub fn process(&self) -> Result<Option<(Role, i32)>> {
        match self {
            Self::None | Self::Search { .. } => Ok(None),
            Self::Import { pid_file, .. } => Ok(Some((Role::Codex, read_pid(pid_file)?))),
        }
    }

    pub async fn stop_searches(&mut self) -> Result<()> {
        if let Self::Search { stop, loops, .. } = self {
            stop.send_replace(true);
            while let Some(ended) = loops.join_next().await {
                ended??;
            }
        }
        Ok(())
    }

    pub async fn finish(mut self) -> Result<Evidence> {
        self.stop_searches().await?;
        match self {
            Self::None => Ok(Evidence::None),
            Self::Search { log, .. } => Ok(Evidence::Search(snapshot(&log)?)),
            Self::Import {
                mut reader, log, ..
            } => {
                if let Some(ended) = reader.try_join_next() {
                    ended??;
                }
                Ok(Evidence::Import(snapshot(&log)?))
            }
        }
    }
}

#[derive(Deserialize)]
struct Matched {
    conversation_id: String,
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum SearchEvent {
    SavedMatches {
        matches: Vec<Matched>,
        gaps: Vec<String>,
    },
    Done,
    Failure {
        message: String,
    },
    #[serde(other)]
    Other,
}

async fn search(directory: &Path, expected: &str) -> Result<SearchRequest> {
    let sent = Instant::now();
    let stream = agent_cli::service::connect(directory).await?;
    let (reader, mut writer) = stream.into_split();
    let command = json!({
        "type": "search_history",
        "query": SEARCH_QUERY,
        "limit": SEARCH_LIMIT,
        "mode": "keyword",
    });
    writer.write_all(format!("{command}\n").as_bytes()).await?;
    let mut lines = BufReader::new(reader).lines();
    let mut result = None;
    timeout(DEADLINE, async {
        while let Some(line) = lines.next_line().await? {
            match serde_json::from_str(&line)? {
                SearchEvent::SavedMatches { matches, gaps } => result = Some((matches, gaps)),
                SearchEvent::Done => {
                    let done = Instant::now();
                    let (matches, gaps) = result.context("The search finished without matches")?;
                    return Ok(SearchRequest {
                        sent,
                        done,
                        expected_found: matches
                            .iter()
                            .any(|matched| matched.conversation_id == expected),
                        matches: matches.len(),
                        gaps,
                    });
                }
                SearchEvent::Failure { message } => bail!("History search failed: {message}"),
                SearchEvent::Other => {}
            }
        }
        bail!("The coordinator closed the history search")
    })
    .await
    .context("A history search did not finish")?
}

#[derive(Deserialize)]
struct Progress {
    phase: ImportPhase,
    items_added: u32,
    threads_imported: u32,
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ImportEvent {
    ImportProgress {
        progress: Progress,
    },
    Done,
    Failure {
        message: String,
    },
    #[serde(other)]
    Other,
}

async fn import_from_every_registered_node(
    directory: PathBuf,
    log: Log<ImportProgress>,
) -> Result<()> {
    let stream = agent_cli::service::connect(&directory).await?;
    let (reader, mut writer) = stream.into_split();
    let command = json!({ "type": "import_codex", "hosts": [] });
    writer.write_all(format!("{command}\n").as_bytes()).await?;
    let mut lines = BufReader::new(reader).lines();
    while let Some(line) = lines.next_line().await? {
        match serde_json::from_str(&line)? {
            ImportEvent::ImportProgress { progress } => push(
                &log,
                ImportProgress {
                    at: Instant::now(),
                    phase: progress.phase,
                    items_added: progress.items_added,
                    threads_imported: progress.threads_imported,
                },
            )?,
            ImportEvent::Done => return Ok(()),
            ImportEvent::Failure { message } => bail!("Codex import failed: {message}"),
            ImportEvent::Other => {}
        }
    }
    bail!("The coordinator closed the import")
}
