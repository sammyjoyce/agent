//! Program Resume Protocol (`OSC 7577`) encoding, authentication, and state tracking
//! for Rex and compatible terminals.
//!
//! Spec: <https://www.superlogical.com/rex/docs/build/program-resume>

use std::{
    env, fmt,
    io::{self, Write},
    path::Path,
    time::{SystemTime, UNIX_EPOCH},
};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use crossterm::execute;
use sha2::{Digest, Sha256};

pub use crate::serialized_spawn::PROGRAM_RESUME_TOKEN_ENV;

/// Minimum limits every spec-compliant terminal accepts.
const MAX_SEQUENCE_BYTES: usize = 2048;
const MAX_ARGV_ELEMENTS: usize = 64;
const DEFAULT_PROGRAM: &str = "beep-boop";

/// Which conversation the terminal should re-open when resuming `beep-boop chat`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum ResumeTarget {
    Main,
    Conversation(String),
}

/// Opaque authentication token read once from `OSC7577_TOKEN` and stripped from the
/// process environment so child processes can never spoof or replace this pane's resume command.
pub struct ProgramResumeToken(String);

impl fmt::Debug for ProgramResumeToken {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("ProgramResumeToken([redacted])")
    }
}

impl ProgramResumeToken {
    /// Wrap a raw non-empty token string (primarily for deterministic tests).
    pub fn from_raw(token: impl Into<String>) -> Option<Self> {
        let token = token.into();
        (!token.is_empty()).then_some(Self(token))
    }

    /// Read and remove `OSC7577_TOKEN` from the process environment.
    ///
    /// Always removes the variable when present (even if empty or non-UTF-8) so no
    /// child process ever inherits it.
    ///
    /// # Safety
    /// Must be called while the process is single-threaded (for example at the start of
    /// `main` before creating any worker threads or spawning child processes), because
    /// mutating the process environment concurrently with reads is undefined behavior.
    pub unsafe fn take_from_env_single_threaded() -> Option<Self> {
        let raw = env::var_os(PROGRAM_RESUME_TOKEN_ENV)?;
        // SAFETY: Caller guarantees the process is single-threaded.
        unsafe { env::remove_var(PROGRAM_RESUME_TOKEN_ENV) };
        raw.into_string().ok().and_then(Self::from_raw)
    }

    fn as_str(&self) -> &str {
        &self.0
    }
}

/// The command and working directory a terminal executes to bring this session back.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProgramResumeCommand {
    argv: Vec<String>,
    cwd: Option<String>,
}

impl ProgramResumeCommand {
    pub fn new(argv: Vec<String>, cwd: Option<String>) -> Self {
        Self { argv, cwd }
    }

    pub fn argv(&self) -> &[String] {
        &self.argv
    }

    pub fn cwd(&self) -> Option<&str> {
        self.cwd.as_deref()
    }

    fn is_reportable(&self) -> bool {
        let Some(program) = self.argv.first() else {
            return false;
        };
        if self.argv.len() > MAX_ARGV_ELEMENTS {
            return false;
        }
        let is_bare_name = !program.is_empty()
            && program != "."
            && program != ".."
            && !program.starts_with('-')
            && !program.contains('/')
            && !program.contains('\\');
        if !is_bare_name && !Path::new(program).is_absolute() {
            return false;
        }
        if !self.argv.iter().all(|arg| is_reportable_text(arg)) {
            return false;
        }
        if let Some(cwd) = &self.cwd
            && !(Path::new(cwd).is_absolute() && is_reportable_text(cwd))
        {
            return false;
        }
        true
    }

    /// Encode this command as an authenticated `OSC 7577` sequence.
    /// Returns `None` if the protocol cannot safely carry the command.
    pub fn encode(
        &self,
        token: &ProgramResumeToken,
        pid: u32,
        unix_seconds: u64,
    ) -> Option<String> {
        if !self.is_reportable() {
            return None;
        }
        let encoded_argv = self
            .argv
            .iter()
            .map(|arg| STANDARD.encode(arg.as_bytes()))
            .collect::<Vec<_>>()
            .join(",");
        let mut pairs = Vec::with_capacity(2);
        pairs.push(format!("argv={encoded_argv}"));
        if let Some(cwd) = &self.cwd {
            pairs.push(format!("cwd={}", STANDARD.encode(cwd.as_bytes())));
        }
        let sequence = format_authenticated(&pairs, token, pid, unix_seconds);
        (sequence.len() <= MAX_SEQUENCE_BYTES).then_some(sequence)
    }
}

/// Encode an authenticated `OSC 7577` sequence that removes this process's registered command.
pub fn encode_clear(token: &ProgramResumeToken, pid: u32, unix_seconds: u64) -> String {
    format_authenticated(&["clear=1"], token, pid, unix_seconds)
}

fn format_authenticated(
    pairs: &[impl AsRef<str>],
    token: &ProgramResumeToken,
    pid: u32,
    unix_seconds: u64,
) -> String {
    let mut body = format!("pid={pid}:time={unix_seconds}");
    for pair in pairs {
        body.push(':');
        body.push_str(pair.as_ref());
    }
    // Plain SHA-256 with the token appended after `:`, as required by the OSC 7577 spec
    // (designed so shell scripts can compute MACs with `sha256sum`).
    let mut hasher = Sha256::new();
    hasher.update(body.as_bytes());
    hasher.update(b":");
    hasher.update(token.as_str().as_bytes());
    let mac = hex::encode(hasher.finalize());
    format!("\x1b]7577;{body}:mac={mac}\x1b\\")
}

fn is_reportable_text(text: &str) -> bool {
    !text.chars().any(char::is_control)
}

fn unix_timestamp_seconds() -> Option<u64> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|duration| duration.as_secs())
}

/// Launch-time scope that must survive a terminal restart (when the terminal re-execs
/// the resume command without the original shell environment).
///
/// Scope flags are kept verbatim as typed (order, `--flag=value` vs `--flag value`
/// spelling, and raw relative/absolute paths against the preserved launch `cwd`) so
/// terminals such as Rex can verify them with `resume.trust.*.flags` against the
/// original process command line. Transient options such as initial prompts,
/// `--sidechat`, `--conversation`, and `--model` overrides are excluded: repeating a
/// prompt would re-send it, and conversation model settings persist on the coordinator.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ProgramResumeScope {
    pub cwd: Option<String>,
    pub scope_args: Vec<String>,
}

/// Command builder for interactive `beep-boop chat` sessions.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct ProgramResumeProfile {
    program: String,
    cwd: Option<String>,
    scope_args: Vec<String>,
}

impl ProgramResumeProfile {
    pub(super) fn for_chat(scope: ProgramResumeScope) -> Self {
        Self {
            program: DEFAULT_PROGRAM.into(),
            cwd: scope.cwd,
            scope_args: scope.scope_args,
        }
    }

    pub(super) fn command_for(&self, target: &ResumeTarget) -> ProgramResumeCommand {
        let mut argv = Vec::with_capacity(4 + self.scope_args.len());
        argv.push(self.program.clone());
        argv.push("chat".into());
        if let ResumeTarget::Conversation(conversation_id) = target {
            argv.push("--conversation".into());
            argv.push(conversation_id.clone());
        }
        argv.extend(self.scope_args.iter().cloned());
        ProgramResumeCommand::new(argv, self.cwd.clone())
    }
}

/// Configuration handing the terminal's resume token and launch scope into the TUI.
pub struct TuiResume {
    token: ProgramResumeToken,
    profile: ProgramResumeProfile,
}

impl fmt::Debug for TuiResume {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("TuiResume")
            .field("token", &self.token)
            .field("profile", &self.profile)
            .finish()
    }
}

impl TuiResume {
    pub fn new(token: ProgramResumeToken, scope: ProgramResumeScope) -> Self {
        Self {
            token,
            profile: ProgramResumeProfile::for_chat(scope),
        }
    }

    pub(super) fn into_reporter(self) -> ProgramResumeReporter {
        ProgramResumeReporter::new(self.token, self.profile)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum TerminalResumeState {
    Empty,
    Registered(ProgramResumeCommand),
}

/// Stateful `OSC 7577` reporter owned by the TUI screen.
///
/// Tracks the terminal's actual registered state rather than the last attempted command,
/// so an unreportable command clears an older registered command once without ever leaving
/// phantom state or emitting spurious clears. Never clears on `Drop`: only an explicit
/// user-initiated quit clears the terminal's record, preserving resume across `SIGTERM`,
/// `SIGHUP`, and terminal restarts.
pub(super) struct ProgramResumeReporter {
    token: ProgramResumeToken,
    profile: ProgramResumeProfile,
    state: TerminalResumeState,
}

impl ProgramResumeReporter {
    pub(super) fn new(token: ProgramResumeToken, profile: ProgramResumeProfile) -> Self {
        Self {
            token,
            profile,
            state: TerminalResumeState::Empty,
        }
    }

    pub(super) fn sync(
        &mut self,
        output: &mut impl Write,
        target: Option<&ResumeTarget>,
    ) -> io::Result<()> {
        let Some(now) = unix_timestamp_seconds() else {
            return Ok(());
        };
        self.sync_at(output, target, std::process::id(), now)
    }

    pub(super) fn refresh(&mut self, output: &mut impl Write) -> io::Result<()> {
        let Some(now) = unix_timestamp_seconds() else {
            return Ok(());
        };
        self.refresh_at(output, std::process::id(), now)
    }

    pub(super) fn clear_on_user_exit(&mut self, output: &mut impl Write) -> io::Result<()> {
        let Some(now) = unix_timestamp_seconds() else {
            return Ok(());
        };
        self.clear_at(output, std::process::id(), now)
    }

    fn sync_at(
        &mut self,
        output: &mut impl Write,
        target: Option<&ResumeTarget>,
        pid: u32,
        unix_seconds: u64,
    ) -> io::Result<()> {
        let encodable = target.and_then(|target| {
            let command = self.profile.command_for(target);
            let sequence = command.encode(&self.token, pid, unix_seconds)?;
            Some((command, sequence))
        });
        match (&self.state, encodable) {
            (TerminalResumeState::Registered(current), Some((next, _))) if current == &next => {
                Ok(())
            }
            (_, Some((next, sequence))) => {
                execute!(output, Osc7577Command(&sequence))?;
                self.state = TerminalResumeState::Registered(next);
                Ok(())
            }
            (TerminalResumeState::Registered(_), None) => {
                let sequence = encode_clear(&self.token, pid, unix_seconds);
                execute!(output, Osc7577Command(&sequence))?;
                self.state = TerminalResumeState::Empty;
                Ok(())
            }
            (TerminalResumeState::Empty, None) => Ok(()),
        }
    }

    fn refresh_at(
        &mut self,
        output: &mut impl Write,
        pid: u32,
        unix_seconds: u64,
    ) -> io::Result<()> {
        let TerminalResumeState::Registered(command) = &self.state else {
            return Ok(());
        };
        if let Some(sequence) = command.encode(&self.token, pid, unix_seconds) {
            execute!(output, Osc7577Command(&sequence))?;
        } else {
            let sequence = encode_clear(&self.token, pid, unix_seconds);
            execute!(output, Osc7577Command(&sequence))?;
            self.state = TerminalResumeState::Empty;
        }
        Ok(())
    }

    fn clear_at(&mut self, output: &mut impl Write, pid: u32, unix_seconds: u64) -> io::Result<()> {
        if matches!(self.state, TerminalResumeState::Registered(_)) {
            let sequence = encode_clear(&self.token, pid, unix_seconds);
            execute!(output, Osc7577Command(&sequence))?;
            self.state = TerminalResumeState::Empty;
        }
        Ok(())
    }
}

struct Osc7577Command<'a>(&'a str);

impl crossterm::Command for Osc7577Command<'_> {
    fn write_ansi(&self, f: &mut impl fmt::Write) -> fmt::Result {
        f.write_str(self.0)
    }

    #[cfg(windows)]
    fn execute_winapi(&self) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SPEC_TOKEN: &str = "dummy-token-replace-me";
    const SPEC_PID: u32 = 74877;
    const SPEC_TIME: u64 = 1795543200;

    fn spec_token() -> ProgramResumeToken {
        ProgramResumeToken::from_raw(SPEC_TOKEN).unwrap()
    }

    #[derive(Debug, PartialEq, Eq)]
    enum Decoded {
        Resume {
            pid: u32,
            time: u64,
            argv: Vec<String>,
            cwd: Option<String>,
        },
        Clear {
            pid: u32,
            time: u64,
        },
    }

    fn parse_authenticated_reports(raw: &[u8], token: &str) -> Vec<Decoded> {
        let text = std::str::from_utf8(raw).expect("valid UTF-8");
        let mut reports = Vec::new();
        let mut rest = text;
        while let Some(start) = rest.find("\x1b]7577;") {
            let after_prefix = &rest[start + "\x1b]7577;".len()..];
            let end = after_prefix.find("\x1b\\").expect("ST terminator");
            let payload = &after_prefix[..end];
            rest = &after_prefix[end + "\x1b\\".len()..];

            let (body, mac) = payload.rsplit_once(":mac=").expect("trailing mac");
            assert_eq!(mac.len(), 64);
            let mut hasher = Sha256::new();
            hasher.update(format!("{body}:{token}").as_bytes());
            assert_eq!(hex::encode(hasher.finalize()), mac, "valid SHA-256 MAC");

            let mut pid = None;
            let mut time = None;
            let mut argv = None;
            let mut cwd = None;
            let mut clear = false;
            for pair in body.split(':') {
                let (key, value) = pair.split_once('=').expect("key=value");
                match key {
                    "pid" => pid = Some(value.parse::<u32>().unwrap()),
                    "time" => time = Some(value.parse::<u64>().unwrap()),
                    "clear" => {
                        assert_eq!(value, "1");
                        clear = true;
                    }
                    "argv" => {
                        argv = Some(
                            value
                                .split(',')
                                .map(|item| {
                                    String::from_utf8(STANDARD.decode(item).unwrap()).unwrap()
                                })
                                .collect::<Vec<_>>(),
                        );
                    }
                    "cwd" => {
                        cwd = Some(String::from_utf8(STANDARD.decode(value).unwrap()).unwrap());
                    }
                    other => panic!("unexpected OSC 7577 key: {other}"),
                }
            }
            let pid = pid.expect("pid");
            let time = time.expect("time");
            if clear {
                reports.push(Decoded::Clear { pid, time });
            } else {
                reports.push(Decoded::Resume {
                    pid,
                    time,
                    argv: argv.expect("argv"),
                    cwd,
                });
            }
        }
        reports
    }

    #[test]
    fn matches_official_spec_test_vectors() {
        let token = spec_token();

        let nvim = ProgramResumeCommand::new(
            vec![
                "nvim".into(),
                "-S".into(),
                "/home/user/.local/state/nvim/sessions/8f2c1d.vim".into(),
            ],
            None,
        )
        .encode(&token, SPEC_PID, SPEC_TIME)
        .unwrap();
        assert_eq!(
            nvim,
            "\x1b]7577;pid=74877:time=1795543200:argv=bnZpbQ==,LVM=,L2hvbWUvdXNlci8ubG9jYWwvc3RhdGUvbnZpbS9zZXNzaW9ucy84ZjJjMWQudmlt:mac=9dbb99bfb856749a87563839d7ce9062818d78cf25909db93f309e0cd3b1909b\x1b\\"
        );

        let lazygit = ProgramResumeCommand::new(
            vec!["lazygit".into()],
            Some("/home/user/src/project".into()),
        )
        .encode(&token, SPEC_PID, SPEC_TIME)
        .unwrap();
        assert_eq!(
            lazygit,
            "\x1b]7577;pid=74877:time=1795543200:argv=bGF6eWdpdA==:cwd=L2hvbWUvdXNlci9zcmMvcHJvamVjdA==:mac=35cb909805c380336efd3689a125acc774a9dec8422a1d21492ebec06ca758e1\x1b\\"
        );

        let wrapper = ProgramResumeCommand::new(
            vec!["resume-wrap".into(), "ssh".into(), "devbox".into()],
            None,
        )
        .encode(&token, 90412, SPEC_TIME)
        .unwrap();
        assert_eq!(
            wrapper,
            "\x1b]7577;pid=90412:time=1795543200:argv=cmVzdW1lLXdyYXA=,c3No,ZGV2Ym94:mac=e76149d0ba54a83570ffab0583867dacdfa23928ba9d18604f0badea88b62b65\x1b\\"
        );

        assert_eq!(
            encode_clear(&token, SPEC_PID, SPEC_TIME),
            "\x1b]7577;pid=74877:time=1795543200:clear=1:mac=c30603369f98fef581a4098be889175b0c74f0641e49f8b25f4326cb38f97c93\x1b\\"
        );
    }

    #[test]
    fn token_debug_redacts_secret_and_rejects_empty() {
        assert!(ProgramResumeToken::from_raw("").is_none());
        let token = spec_token();
        let debug = format!("{token:?}");
        assert!(!debug.contains(SPEC_TOKEN));
        assert!(debug.contains("redacted"));
    }

    #[test]
    fn rejects_unreportable_commands_and_keeps_valid_edge_cases() {
        let token = spec_token();
        let invalid = [
            ProgramResumeCommand::new(vec![], None),
            ProgramResumeCommand::new(vec!["".into()], None),
            ProgramResumeCommand::new(vec![".".into()], None),
            ProgramResumeCommand::new(vec!["..".into()], None),
            ProgramResumeCommand::new(vec!["./beep-boop".into()], None),
            ProgramResumeCommand::new(vec!["bin/beep-boop".into()], None),
            ProgramResumeCommand::new(vec!["-beep-boop".into()], None),
            ProgramResumeCommand::new(vec!["beep-boop".into(), "line\nbreak".into()], None),
            ProgramResumeCommand::new(vec!["beep-boop".into(), "c1\u{009b}ctrl".into()], None),
            ProgramResumeCommand::new(vec!["beep-boop".into()], Some("relative/dir".into())),
            ProgramResumeCommand::new(vec!["beep-boop".into()], Some("/tmp/\x1b".into())),
            ProgramResumeCommand::new(
                std::iter::once("beep-boop".into())
                    .chain(std::iter::repeat_n("x".into(), 64))
                    .collect(),
                None,
            ),
            ProgramResumeCommand::new(vec!["beep-boop".into(), "x".repeat(2048)], None),
        ];
        for command in invalid {
            assert_eq!(
                command.encode(&token, SPEC_PID, SPEC_TIME),
                None,
                "{command:?}"
            );
        }

        // Empty non-program argument and absolute program path remain valid.
        let empty_arg = ProgramResumeCommand::new(vec!["beep-boop".into(), "".into()], None)
            .encode(&token, SPEC_PID, SPEC_TIME)
            .unwrap();
        assert!(empty_arg.contains(":argv=YmVlcC1ib29w,:mac="));

        assert!(
            ProgramResumeCommand::new(vec!["/usr/local/bin/beep-boop".into()], Some("/".into()))
                .encode(&token, SPEC_PID, SPEC_TIME)
                .is_some()
        );
    }

    #[test]
    fn profile_preserves_scope_flags_as_typed_after_chat_target() {
        let profile = ProgramResumeProfile::for_chat(ProgramResumeScope {
            cwd: Some("/workspace/project".into()),
            scope_args: vec![
                "--state-dir=/var/tmp/state".into(),
                "--config".into(),
                "rel-agent.toml".into(),
                "--coordinator".into(),
                "devbox".into(),
            ],
        });
        assert_eq!(
            profile.command_for(&ResumeTarget::Main),
            ProgramResumeCommand::new(
                vec![
                    "beep-boop".into(),
                    "chat".into(),
                    "--state-dir=/var/tmp/state".into(),
                    "--config".into(),
                    "rel-agent.toml".into(),
                    "--coordinator".into(),
                    "devbox".into(),
                ],
                Some("/workspace/project".into()),
            )
        );
        assert_eq!(
            profile.command_for(&ResumeTarget::Conversation("42".into())),
            ProgramResumeCommand::new(
                vec![
                    "beep-boop".into(),
                    "chat".into(),
                    "--conversation".into(),
                    "42".into(),
                    "--state-dir=/var/tmp/state".into(),
                    "--config".into(),
                    "rel-agent.toml".into(),
                    "--coordinator".into(),
                    "devbox".into(),
                ],
                Some("/workspace/project".into()),
            )
        );
    }

    #[test]
    fn reporter_tracks_actual_terminal_state_without_spurious_clears() {
        let profile = ProgramResumeProfile::for_chat(ProgramResumeScope {
            cwd: Some("/workspace".into()),
            ..Default::default()
        });
        let mut reporter = ProgramResumeReporter::new(spec_token(), profile);
        let mut out = Vec::new();
        let bad = ResumeTarget::Conversation("bad\nid".into());
        let other_bad = ResumeTarget::Conversation("other\x1bid".into());
        let conv42 = ResumeTarget::Conversation("42".into());

        // No conversation yet and unreportable conversation while Empty emit nothing.
        reporter
            .sync_at(&mut out, None, SPEC_PID, SPEC_TIME)
            .unwrap();
        reporter
            .sync_at(&mut out, Some(&bad), SPEC_PID, SPEC_TIME)
            .unwrap();
        reporter
            .refresh_at(&mut out, SPEC_PID, SPEC_TIME + 1)
            .unwrap();
        reporter
            .clear_at(&mut out, SPEC_PID, SPEC_TIME + 2)
            .unwrap();
        assert!(out.is_empty(), "empty state must emit no clears or reports");

        // Register Main; duplicate sync is a no-op.
        reporter
            .sync_at(
                &mut out,
                Some(&ResumeTarget::Main),
                SPEC_PID,
                SPEC_TIME + 10,
            )
            .unwrap();
        reporter
            .sync_at(
                &mut out,
                Some(&ResumeTarget::Main),
                SPEC_PID,
                SPEC_TIME + 11,
            )
            .unwrap();
        // Switch to conversation 42.
        reporter
            .sync_at(&mut out, Some(&conv42), SPEC_PID, SPEC_TIME + 12)
            .unwrap();
        // Refresh after SIGCONT re-emits with fresh timestamp.
        reporter
            .refresh_at(&mut out, SPEC_PID, SPEC_TIME + 20)
            .unwrap();
        // Switching to an unreportable command clears once and resets state to Empty.
        reporter
            .sync_at(&mut out, Some(&bad), SPEC_PID, SPEC_TIME + 21)
            .unwrap();
        // A second unreportable command or clear_on_user_exit emits NO duplicate clear.
        reporter
            .sync_at(&mut out, Some(&other_bad), SPEC_PID, SPEC_TIME + 22)
            .unwrap();
        reporter
            .clear_at(&mut out, SPEC_PID, SPEC_TIME + 23)
            .unwrap();

        // Register again, then explicitly clear on user exit (once only).
        reporter
            .sync_at(
                &mut out,
                Some(&ResumeTarget::Main),
                SPEC_PID,
                SPEC_TIME + 30,
            )
            .unwrap();
        reporter
            .clear_at(&mut out, SPEC_PID, SPEC_TIME + 31)
            .unwrap();
        reporter
            .clear_at(&mut out, SPEC_PID, SPEC_TIME + 32)
            .unwrap();

        assert_eq!(
            parse_authenticated_reports(&out, SPEC_TOKEN),
            vec![
                Decoded::Resume {
                    pid: SPEC_PID,
                    time: SPEC_TIME + 10,
                    argv: vec!["beep-boop".into(), "chat".into()],
                    cwd: Some("/workspace".into()),
                },
                Decoded::Resume {
                    pid: SPEC_PID,
                    time: SPEC_TIME + 12,
                    argv: vec![
                        "beep-boop".into(),
                        "chat".into(),
                        "--conversation".into(),
                        "42".into(),
                    ],
                    cwd: Some("/workspace".into()),
                },
                Decoded::Resume {
                    pid: SPEC_PID,
                    time: SPEC_TIME + 20,
                    argv: vec![
                        "beep-boop".into(),
                        "chat".into(),
                        "--conversation".into(),
                        "42".into(),
                    ],
                    cwd: Some("/workspace".into()),
                },
                Decoded::Clear {
                    pid: SPEC_PID,
                    time: SPEC_TIME + 21,
                },
                Decoded::Resume {
                    pid: SPEC_PID,
                    time: SPEC_TIME + 30,
                    argv: vec!["beep-boop".into(), "chat".into()],
                    cwd: Some("/workspace".into()),
                },
                Decoded::Clear {
                    pid: SPEC_PID,
                    time: SPEC_TIME + 31,
                },
            ]
        );
    }
}
