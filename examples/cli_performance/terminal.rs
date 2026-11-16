//! The CLI in a PTY, observed through visible `vt100` cells.

use std::{
    collections::VecDeque,
    num::NonZeroU16,
    process::Stdio,
    sync::{Arc, Mutex, MutexGuard},
    time::Instant,
};

use anyhow::{Context, Result, anyhow, ensure};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    process::{Child, ChildStdin, ChildStdout, Command},
    sync::oneshot,
    task::JoinHandle,
    time::timeout,
};

use crate::DEADLINE;

pub const ROWS: u16 = 32;
pub const COLUMNS: u16 = 100;
const PLACEHOLDER: &str = "Ask Beep Boop to do anything";
const BUSY: &str = "esc to interrupt";

#[derive(Clone, Copy, Debug)]
pub enum Sight {
    Shows(&'static str),
    /// The composer is empty and the prompt is a placed transcript cell, not
    /// a pending one that is still being sent.
    Admitted(&'static str),
    Settled(&'static str),
    Stopped,
}

impl Sight {
    fn holds(self, screen: &vt100::Screen) -> bool {
        let contents = screen.contents();
        let shows = |text: &str| contents.contains(text);
        let line = |line: &str| contents.lines().any(|row| row.trim() == line);
        match self {
            Self::Shows(text) => shows(text),
            Self::Admitted(prompt) => {
                shows(PLACEHOLDER)
                    && shows(&format!("› {prompt}"))
                    && !shows("Sending steering messages")
                    && !shows("sending…")
            }
            Self::Settled(text) => shows(text) && !shows(BUSY),
            Self::Stopped => line("• Interrupted") && !shows(BUSY),
        }
    }
}

/// The emulator owns actual cursor position, including printed characters and
/// scrolling. Cursor replies travel through the fixture's existing input owner.
#[derive(Default)]
struct Replies(Vec<u8>);
impl vt100::Callbacks for Replies {
    fn unhandled_csi(
        &mut self,
        screen: &mut vt100::Screen,
        first: Option<u8>,
        second: Option<u8>,
        parameters: &[&[u16]],
        command: char,
    ) {
        if first.is_none()
            && second.is_none()
            && command == 'n'
            && parameters.len() == 1
            && parameters[0] == [6]
        {
            let (row, column) = screen.cursor_position();
            self.0
                .extend(format!("\x1b[{};{}R", row + 1, column + 1).bytes());
        }
    }
}

fn parser() -> Result<vt100::Parser<Replies>> {
    Ok(vt100::Parser::new_with_callbacks(
        NonZeroU16::new(ROWS).context("Invalid terminal height")?,
        NonZeroU16::new(COLUMNS).context("Invalid terminal width")?,
        0,
        Replies::default(),
    ))
}

struct Screen {
    parser: vt100::Parser<Replies>,
    armed: VecDeque<(Sight, oneshot::Sender<Instant>)>,
    received: usize,
}

impl Screen {
    fn arm(&mut self, sights: Vec<Sight>) -> Result<Sightings> {
        ensure!(self.armed.is_empty(), "An earlier sight is still pending");
        if let Some(first) = sights.first() {
            ensure!(
                !first.holds(self.parser.screen()),
                "{first:?} was already visible before its key"
            );
        }
        Ok(Sightings(
            sights
                .into_iter()
                .map(|sight| {
                    let (seen, receiver) = oneshot::channel();
                    self.armed.push_back((sight, seen));
                    (sight, receiver)
                })
                .collect(),
        ))
    }

    /// Sights resolve in order; a later one may resolve in the same chunk.
    fn observe(&mut self, bytes: &[u8], at: Instant) -> Vec<u8> {
        self.parser.process(bytes);
        self.received += bytes.len();
        while self
            .armed
            .front()
            .is_some_and(|(sight, _)| sight.holds(self.parser.screen()))
        {
            if let Some((_, seen)) = self.armed.pop_front() {
                let _ = seen.send(at);
            }
        }
        std::mem::take(&mut self.parser.callbacks_mut().0)
    }
}

/// The instants at which armed sights became true, in arming order.
pub struct Sightings(VecDeque<(Sight, oneshot::Receiver<Instant>)>);

impl Sightings {
    pub async fn next(&mut self) -> Result<Instant> {
        let (sight, receiver) = self.0.pop_front().context("No sight remains to wait for")?;
        timeout(DEADLINE, receiver)
            .await
            .with_context(|| format!("{sight:?} did not become visible"))?
            .with_context(|| format!("The CLI exited before {sight:?}"))
    }
}

pub struct Terminal {
    child: Child,
    input: Arc<tokio::sync::Mutex<ChildStdin>>,
    screen: Arc<Mutex<Screen>>,
    reader: JoinHandle<Result<()>>,
}

impl Terminal {
    /// Arms `sights` before the CLI exists, so the first frame is observed.
    pub fn spawn(mut command: Command, sights: Vec<Sight>) -> Result<(Instant, Self, Sightings)> {
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let mut screen = Screen {
            parser: parser()?,
            armed: VecDeque::new(),
            received: 0,
        };
        let sightings = screen.arm(sights)?;
        let screen = Arc::new(Mutex::new(screen));
        let spawned = Instant::now();
        let mut child = command.spawn()?;
        let input = Arc::new(tokio::sync::Mutex::new(
            child.stdin.take().context("Missing terminal input")?,
        ));
        let output = child.stdout.take().context("Missing terminal output")?;
        let reader = tokio::spawn(read(output, screen.clone(), input.clone()));
        Ok((
            spawned,
            Self {
                child,
                input,
                screen,
                reader,
            },
            sightings,
        ))
    }

    /// Arms `sights`, then writes `key`. Returns the instant before the write.
    pub async fn press(&self, key: &[u8], sights: Vec<Sight>) -> Result<(Instant, Sightings)> {
        let sightings = locked(&self.screen)?.arm(sights)?;
        let mut input = self.input.lock().await;
        let pressed = Instant::now();
        input.write_all(key).await?;
        Ok((pressed, sightings))
    }

    /// Types `text` and waits until the composer shows it, so a measured Enter
    /// is a keystroke of its own.
    pub async fn compose(&self, text: &'static str) -> Result<()> {
        self.press(text.as_bytes(), vec![Sight::Shows(text)])
            .await?
            .1
            .next()
            .await
            .map(drop)
    }

    pub fn contents(&self) -> String {
        locked(&self.screen).map_or_else(
            |error| error.to_string(),
            |screen| screen.parser.screen().contents(),
        )
    }

    /// Detaches with `/exit` while output keeps draining. Returns received bytes.
    pub async fn exit(self) -> Result<usize> {
        self.input.lock().await.write_all(b"/exit\r").await?;
        let Self {
            child,
            screen,
            reader,
            ..
        } = self;
        let (status, drained) = timeout(DEADLINE, async {
            tokio::join!(child.wait_with_output(), reader)
        })
        .await
        .context("CLI terminal cleanup did not finish")?;
        drained??;
        let status = status?;
        let screen = locked(&screen)?;
        ensure!(
            status.status.success(),
            "CLI failed: {}; screen: {}",
            String::from_utf8_lossy(&status.stderr),
            screen.parser.screen().contents()
        );
        Ok(screen.received)
    }

    pub async fn kill(mut self) -> String {
        let _ = self.child.start_kill();
        let stderr = match timeout(DEADLINE, self.child.wait_with_output()).await {
            Ok(Ok(output)) => String::from_utf8_lossy(&output.stderr).into_owned(),
            Ok(Err(error)) => error.to_string(),
            Err(_) => "The terminal fixture did not exit".into(),
        };
        self.reader.abort();
        stderr
    }
}

fn locked(screen: &Mutex<Screen>) -> Result<MutexGuard<'_, Screen>> {
    screen
        .lock()
        .map_err(|_| anyhow!("The terminal screen is unavailable"))
}

/// Owns PTY output for the CLI's whole life, so the CLI never blocks on a
/// full pipe while the benchmark waits on files or sockets.
async fn read(
    mut output: ChildStdout,
    screen: Arc<Mutex<Screen>>,
    input: Arc<tokio::sync::Mutex<ChildStdin>>,
) -> Result<()> {
    let mut buffer = [0; 8192];
    loop {
        let length = output.read(&mut buffer).await?;
        let at = Instant::now();
        if length == 0 {
            return Ok(());
        }
        let replies = locked(&screen)?.observe(&buffer[..length], at);
        if !replies.is_empty() {
            input.lock().await.write_all(&replies).await?;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn screen_observation_requires_visible_cells_and_replies_from_the_real_cursor() {
        let mut screen = parser().unwrap();
        let sentence = "Stored chief conversation is ready.";
        screen.process(sentence.as_bytes());
        screen.process(b"\x1b[2J\x1b[H");
        assert!(!Sight::Shows(sentence).holds(screen.screen()));
        screen.process(b"Storedchief");
        screen.process(b"\x1b[1;7H chief conversation is ready.");
        assert!(Sight::Shows(sentence).holds(screen.screen()));
        screen.process(b"\x1b[6n");
        assert_eq!(screen.callbacks().0, b"\x1b[1;36R");
    }

    fn observed(lines: &[&str]) -> Screen {
        let mut screen = Screen {
            parser: parser().unwrap(),
            armed: VecDeque::new(),
            received: 0,
        };
        screen.observe(lines.join("\r\n").as_bytes(), Instant::now());
        screen
    }

    #[test]
    fn admission_requires_a_cleared_composer_and_no_pending_delivery() {
        let prompt = "Summarize the synthetic invoice backlog.";
        let placed = [
            "› Summarize the synthetic invoice backlog.",
            "• Working (0s • esc to interrupt)",
            "› Ask Beep Boop to do anything",
        ];
        assert!(Sight::Admitted(prompt).holds(observed(&placed).parser.screen()));
        for pending in [
            &[
                "› Summarize the synthetic invoice backlog.",
                "  sending…",
                PLACEHOLDER,
            ][..],
            &[
                "• Sending steering messages",
                "  ↳ Summarize the synthetic invoice backlog.",
                PLACEHOLDER,
            ],
            &["› Summarize the synthetic invoice backlog."],
        ] {
            assert!(!Sight::Admitted(prompt).holds(observed(pending).parser.screen()));
        }
    }

    #[test]
    fn stopped_and_settled_wait_for_the_busy_status_to_clear() {
        let busy = observed(&["• Interrupted", "• Interrupting (1s • esc to interrupt)"]);
        assert!(!Sight::Stopped.holds(busy.parser.screen()));
        assert!(!Sight::Settled("• Interrupted").holds(busy.parser.screen()));
        let stopped = observed(&["• Interrupted", PLACEHOLDER]);
        assert!(Sight::Stopped.holds(stopped.parser.screen()));
        assert!(!Sight::Stopped.holds(observed(&["• Interrupted agent"]).parser.screen()));
    }

    #[tokio::test]
    async fn armed_sights_resolve_in_order_within_one_chunk_and_reject_a_true_precondition() {
        let mut screen = observed(&["Earlier text"]);
        assert!(screen.arm(vec![Sight::Shows("Earlier text")]).is_err());
        let mut sightings = screen
            .arm(vec![Sight::Shows("first"), Sight::Shows("second")])
            .unwrap();
        let at = Instant::now();
        screen.observe(b"\r\nsecond", at);
        assert!(sightings.0.front_mut().unwrap().1.try_recv().is_err());
        screen.observe(b"\r\nfirst", at);
        assert_eq!(sightings.next().await.unwrap(), at);
        assert_eq!(sightings.next().await.unwrap(), at);
    }
}
