//! One way to send a GET with a bearer token from a credential command.
//!
//! The token and the whole request address reach `curl` on standard input, so
//! the process arguments are the same for every request of every source. A
//! request can only go to the configured base address, and `curl` follows no
//! redirect, so the token reaches no other server.

use std::fmt;

use anyhow::{Result, ensure};
use serde::de::DeserializeOwned;

use crate::{
    host::ProcessFailure,
    sources::{read_command, read_command_with_stdin},
};

pub(crate) const REQUEST_SECONDS: u32 = 20;

/// A validated API base address and the command that prints its token.
pub(crate) struct HttpApi {
    label: &'static str,
    base: String,
    credential_command: Vec<String>,
    curl: String,
    max_time: u32,
}

/// The address and the command can name private hosts and secret stores.
impl fmt::Debug for HttpApi {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("HttpApi")
            .field("label", &self.label)
            .finish_non_exhaustive()
    }
}

impl HttpApi {
    pub(crate) fn new(
        label: &'static str,
        url: &str,
        credential_command: Vec<String>,
    ) -> Result<Self> {
        let base = url.trim().trim_end_matches('/').to_owned();
        ensure!(
            (base.starts_with("http://") || base.starts_with("https://"))
                && !base.chars().any(breaks_curl_quoting),
            "{label} URL must be an http:// or https:// base URL"
        );
        ensure!(
            credential_command
                .first()
                .is_some_and(|program| !program.is_empty())
                && credential_command.iter().all(|part| !part.contains('\0')),
            "{label} source needs a credential_command"
        );
        Ok(Self {
            label,
            base,
            credential_command,
            curl: "curl".into(),
            max_time: REQUEST_SECONDS,
        })
    }

    /// Runs the credential command once. A poll makes all its requests on one session.
    pub(crate) async fn open(&self) -> Result<Session<'_>, HttpFailure> {
        let output = read_command(&self.credential_command)
            .await
            .map_err(|_| HttpFailure::Credential)?;
        let token = output.stdout.trim();
        let usable = output.exit_code == 0
            && !output.truncated
            && !token.is_empty()
            && !token
                .chars()
                .any(|character| character.is_control() || matches!(character, '"' | '\\'));
        if !usable {
            return Err(HttpFailure::Credential);
        }
        Ok(Session {
            api: self,
            token: BearerToken(token.to_owned()),
        })
    }

    #[cfg(test)]
    pub(crate) fn with_max_time(mut self, seconds: u32) -> Self {
        self.max_time = seconds;
        self
    }

    #[cfg(test)]
    pub(crate) fn with_curl(mut self, program: String) -> Self {
        self.curl = program;
        self
    }
}

/// The curl config file puts each value in double quotes and reads a backslash as an escape.
fn breaks_curl_quoting(character: char) -> bool {
    character.is_control() || character.is_whitespace() || matches!(character, '"' | '\\')
}

/// A path under the base address. Only a `Target` can be requested.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Target(String);

impl Target {
    /// A path written in the source code, such as "/api/states".
    pub(crate) fn fixed(path: &'static str) -> Self {
        Self(path.to_owned())
    }
}

/// One poll's token. It has no `Clone`, `Debug` or `Serialize`, so it cannot be copied into a log.
struct BearerToken(String);

/// Lives for one `poll` call. The source never touches the token.
pub(crate) struct Session<'a> {
    api: &'a HttpApi,
    token: BearerToken,
}

impl Session<'_> {
    /// One GET, with no retry. Every HTTP status is an `Ok(Reply)`, because a
    /// 404 can be an answer and not a failure.
    pub(crate) async fn get(&self, target: &Target) -> Result<Reply, HttpFailure> {
        let (argv, stdin) = curl_invocation(self.api, target, &self.token);
        let output = read_command_with_stdin(&argv, stdin.as_bytes())
            .await
            .map_err(|error| match error.downcast_ref::<ProcessFailure>() {
                Some(ProcessFailure::NotStarted(_)) => HttpFailure::NotRun,
                _ => HttpFailure::Unreachable,
            })?;
        if output.truncated {
            return Err(HttpFailure::Oversized);
        }
        match output.exit_code {
            0 => {}
            28 => return Err(HttpFailure::TimedOut),
            _ => return Err(HttpFailure::Unreachable),
        }
        let (body, status) = output
            .stdout
            .rsplit_once('\n')
            .ok_or(HttpFailure::Unreachable)?;
        Ok(Reply {
            status: status
                .trim()
                .parse()
                .map_err(|_| HttpFailure::Unreachable)?,
            body: body.to_owned(),
        })
    }
}

/// The only place that knows the curl command line.
///
/// `-q` comes first, so curl does not read the service user's own config file.
/// The command has no `-L`, so curl follows no redirect. `globoff` makes curl
/// send brackets and braces in the address as they are.
fn curl_invocation(api: &HttpApi, target: &Target, token: &BearerToken) -> (Vec<String>, String) {
    let argv = vec![
        api.curl.clone(),
        "-q".into(),
        "-sS".into(),
        "-w".into(),
        "\n%{http_code}".into(),
        "--max-time".into(),
        api.max_time.to_string(),
        "-K".into(),
        "-".into(),
    ];
    let stdin = format!(
        "globoff\nheader = \"Authorization: Bearer {}\"\nurl = \"{}{}\"\n",
        token.0, api.base, target.0
    );
    (argv, stdin)
}

pub(crate) struct Reply {
    pub(crate) status: u16,
    body: String,
}

impl Reply {
    /// The body as `T` when the status is 2xx. The body is dropped here, so it
    /// never reaches a message or a log.
    pub(crate) fn json<T: DeserializeOwned>(self) -> Result<T, HttpFailure> {
        if !(200..300).contains(&self.status) {
            return Err(HttpFailure::Status(self.status));
        }
        serde_json::from_str(&self.body).map_err(|_| HttpFailure::Unreadable)
    }
}

/// Everything that can go wrong with one request. No variant carries text from
/// the server or from the credential command, so none can leak it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum HttpFailure {
    /// The credential command failed, printed too much, or printed an unusable token.
    Credential,
    /// curl did not start. Usually curl is not on the service PATH.
    NotRun,
    /// curl gave up after its time limit.
    TimedOut,
    /// curl ran and got no HTTP response: DNS, a refused connection, TLS.
    Unreachable,
    /// The response passed the capture limit.
    Oversized,
    /// An HTTP status outside 200 to 299.
    Status(u16),
    /// A 2xx body that is not the JSON the source expects.
    Unreadable,
}

/// The one fake server and the one credential helper for every HTTP source test.
/// The source under test runs the real `curl` and the real credential process against them.
#[cfg(test)]
pub(crate) mod testing {
    use std::{
        fs,
        path::Path,
        sync::{Arc, Mutex},
        time::Duration,
    };

    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::{TcpListener, TcpStream},
        task::{JoinHandle, JoinSet},
    };

    use crate::executable_fixture::write_executable;

    /// What the fake server received.
    #[derive(Clone, Debug)]
    pub(crate) struct Seen {
        /// Path and query as sent, such as "/api/states".
        pub(crate) target: String,
        /// The value after "Authorization: Bearer ", when present.
        pub(crate) bearer: Option<String>,
        headers: Vec<(String, String)>,
    }

    impl Seen {
        pub(crate) fn path(&self) -> &str {
            self.target.split('?').next().unwrap_or_default()
        }

        pub(crate) fn header(&self, name: &str) -> Option<&str> {
            self.headers
                .iter()
                .find(|(key, _)| key.eq_ignore_ascii_case(name))
                .map(|(_, value)| value.as_str())
        }
    }

    pub(crate) struct Canned {
        status: u16,
        body: String,
        location: Option<String>,
        hang: bool,
    }

    impl Canned {
        pub(crate) fn json(status: u16, body: serde_json::Value) -> Self {
            Self::text(status, &body.to_string())
        }

        pub(crate) fn text(status: u16, body: &str) -> Self {
            Self {
                status,
                body: body.to_owned(),
                location: None,
                hang: false,
            }
        }

        pub(crate) fn redirect(location: &str) -> Self {
            Self {
                location: Some(location.to_owned()),
                ..Self::text(302, "")
            }
        }

        /// Accepts the request and never answers. Use with `HttpApi::with_max_time(1)`.
        pub(crate) fn hang() -> Self {
            Self {
                hang: true,
                ..Self::text(200, "")
            }
        }
    }

    /// A loopback HTTP server. The handler is the whole script of the test. It
    /// usually closes over shared state that the test edits between polls.
    pub(crate) struct FakeApi {
        /// "http://127.0.0.1:<port>".
        pub(crate) url: String,
        seen: Arc<Mutex<Vec<Seen>>>,
        server: JoinHandle<()>,
    }

    impl FakeApi {
        pub(crate) async fn start(
            handler: impl Fn(&Seen) -> Canned + Send + Sync + 'static,
        ) -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let url = format!("http://{}", listener.local_addr().unwrap());
            let seen = Arc::new(Mutex::new(Vec::new()));
            let handler = Arc::new(handler);
            let record = seen.clone();
            let server = tokio::spawn(async move {
                let mut connections = JoinSet::new();
                while let Ok((socket, _)) = listener.accept().await {
                    connections.spawn(answer(socket, record.clone(), handler.clone()));
                }
            });
            Self { url, seen, server }
        }

        /// Every request so far, in order.
        pub(crate) fn seen(&self) -> Vec<Seen> {
            self.seen.lock().unwrap().clone()
        }

        /// A loopback address where nothing listens.
        pub(crate) fn dead_url() -> String {
            let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            format!("http://{}", listener.local_addr().unwrap())
        }
    }

    impl Drop for FakeApi {
        fn drop(&mut self) {
            self.server.abort();
        }
    }

    async fn answer(
        mut socket: TcpStream,
        record: Arc<Mutex<Vec<Seen>>>,
        handler: Arc<impl Fn(&Seen) -> Canned>,
    ) {
        let mut request = Vec::new();
        let mut chunk = [0_u8; 4096];
        while !request.windows(4).any(|window| window == b"\r\n\r\n") {
            match socket.read(&mut chunk).await {
                Ok(count) if count > 0 => request.extend_from_slice(&chunk[..count]),
                _ => return,
            }
        }
        let request = String::from_utf8_lossy(&request).into_owned();
        let mut lines = request.split("\r\n");
        let target = lines
            .next()
            .and_then(|line| line.split(' ').nth(1))
            .unwrap_or_default()
            .to_owned();
        let headers: Vec<(String, String)> = lines
            .filter_map(|line| line.split_once(':'))
            .map(|(name, value)| (name.trim().to_owned(), value.trim().to_owned()))
            .collect();
        let bearer = headers
            .iter()
            .find(|(name, _)| name.eq_ignore_ascii_case("authorization"))
            .and_then(|(_, value)| value.strip_prefix("Bearer "))
            .map(str::to_owned);
        let seen = Seen {
            target,
            bearer,
            headers,
        };
        let canned = handler(&seen);
        record.lock().unwrap().push(seen);
        if canned.hang {
            tokio::time::sleep(Duration::from_secs(600)).await;
            return;
        }
        let location = canned
            .location
            .map(|location| format!("Location: {location}\r\n"))
            .unwrap_or_default();
        let response = format!(
            "HTTP/1.1 {} Scripted\r\nContent-Type: application/json\r\n{location}Content-Length: {}\r\nConnection: close\r\n\r\n{}",
            canned.status,
            canned.body.len(),
            canned.body
        );
        let _ = socket.write_all(response.as_bytes()).await;
    }

    /// A command that prints `token`. The shell reads the script as data, so a
    /// concurrent spawn that still holds its descriptor cannot block it.
    pub(crate) fn credential_script(dir: &Path, token: &str) -> Vec<String> {
        script(dir, "credential", &format!("printf '%s' '{token}'\n"))
    }

    /// A command that prints a secret-looking line to both streams and fails.
    pub(crate) fn failing_credential_script(dir: &Path) -> Vec<String> {
        script(
            dir,
            "failing-credential",
            "echo example-secret-in-output\necho example-secret-in-errors >&2\nexit 3\n",
        )
    }

    fn script(dir: &Path, name: &str, body: &str) -> Vec<String> {
        let path = dir.join(name);
        fs::write(&path, body).unwrap();
        vec!["sh".into(), path.to_string_lossy().into_owned()]
    }

    /// A stand-in for `curl`. It exits 97 when a process argument holds one of
    /// `forbidden`. Otherwise it runs the real `curl` with `dir` as the place
    /// where curl looks for its own config file, and adds a line to `dir/ran`.
    pub(crate) fn curl_shim(dir: &Path, forbidden: &[&str]) -> String {
        let refused = forbidden
            .iter()
            .map(|text| format!("*'{text}'*"))
            .collect::<Vec<_>>()
            .join("|");
        let home = dir.to_string_lossy();
        let path = dir.join("curl-shim");
        write_executable(
            &path,
            &format!(
                "#!/bin/sh\nfor argument in \"$@\"; do\n  case \"$argument\" in\n    {refused}) echo refused >> '{home}/refused'; exit 97 ;;\n  esac\ndone\necho ran >> '{home}/ran'\nCURL_HOME='{home}' exec curl \"$@\"\n"
            ),
        );
        path.to_string_lossy().into_owned()
    }

    /// How many times the shim ran the real `curl`.
    pub(crate) fn shim_runs(dir: &Path) -> usize {
        fs::read_to_string(dir.join("ran"))
            .map(|log| log.lines().count())
            .unwrap_or(0)
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{
        testing::{Canned, FakeApi, credential_script, failing_credential_script},
        *,
    };

    fn api(url: &str, credential_command: Vec<String>) -> HttpApi {
        HttpApi::new("Example", url, credential_command).unwrap()
    }

    #[test]
    fn curl_invocation_keeps_the_token_and_the_address_out_of_process_arguments() {
        let api = api("https://api.example.test/v1", vec!["true".into()]);
        let (argv, stdin) = curl_invocation(
            &api,
            &Target::fixed("/api/states"),
            &BearerToken("example-token".into()),
        );

        assert_eq!(
            argv,
            [
                "curl",
                "-q",
                "-sS",
                "-w",
                "\n%{http_code}",
                "--max-time",
                "20",
                "-K",
                "-"
            ]
        );
        assert_eq!(
            stdin,
            "globoff\nheader = \"Authorization: Bearer example-token\"\nurl = \"https://api.example.test/v1/api/states\"\n"
        );
    }

    #[test]
    fn an_address_that_would_break_the_curl_config_is_refused() {
        for refused in [
            "http://home.example.test:8123/\"",
            "http://home.example.test:8123/\\",
            "http://home.example.test:8123/a b",
            "ftp://home.example.test",
        ] {
            assert_eq!(
                HttpApi::new("Example", refused, vec!["true".into()])
                    .unwrap_err()
                    .to_string(),
                "Example URL must be an http:// or https:// base URL",
                "{refused}"
            );
        }
        assert_eq!(
            HttpApi::new("Example", "https://api.example.test", Vec::new())
                .unwrap_err()
                .to_string(),
            "Example source needs a credential_command"
        );
    }

    #[test]
    fn debug_output_shows_neither_the_address_nor_the_credential_command() {
        let api = api(
            "https://private.example.test/v1",
            vec!["example-secrets".into(), "read".into()],
        );
        let shown = format!("{api:?}");
        assert_eq!(shown, "HttpApi { label: \"Example\", .. }");
    }

    #[tokio::test]
    async fn a_request_reaches_the_server_with_the_bearer_token() {
        let server = FakeApi::start(|_| Canned::json(200, json!({ "ok": true }))).await;
        let dir = tempfile::tempdir().unwrap();
        let api = api(&server.url, credential_script(dir.path(), "example-token"));

        let reply = api
            .open()
            .await
            .unwrap()
            .get(&Target::fixed("/api/states"))
            .await
            .unwrap();

        assert_eq!(
            reply.json::<serde_json::Value>().unwrap(),
            json!({ "ok": true })
        );
        let seen = server.seen();
        assert_eq!(seen.len(), 1);
        assert_eq!(seen[0].target, "/api/states");
        assert_eq!(seen[0].bearer.as_deref(), Some("example-token"));
    }

    #[tokio::test]
    async fn credential_failures_and_unusable_tokens_are_credential_failures() {
        let server = FakeApi::start(|_| Canned::json(200, json!({}))).await;
        let dir = tempfile::tempdir().unwrap();
        let mut commands = vec![
            failing_credential_script(dir.path()),
            vec!["/nonexistent/example-secrets".into()],
        ];
        for (index, token) in ["", "two\nlines", "quo\"te", "back\\slash"]
            .iter()
            .enumerate()
        {
            let unusable = dir.path().join(index.to_string());
            std::fs::create_dir(&unusable).unwrap();
            commands.push(credential_script(&unusable, token));
        }
        for command in commands {
            let api = api(&server.url, command);
            assert_eq!(api.open().await.err(), Some(HttpFailure::Credential));
        }
        assert!(
            server.seen().is_empty(),
            "no request leaves without a usable token"
        );
    }

    #[tokio::test]
    async fn a_hung_server_is_timed_out_a_dead_port_is_unreachable_and_a_missing_curl_is_not_run() {
        let dir = tempfile::tempdir().unwrap();
        let command = credential_script(dir.path(), "example-token");
        let target = Target::fixed("/anything");

        let hung = FakeApi::start(|_| Canned::hang()).await;
        let slow = api(&hung.url, command.clone()).with_max_time(1);
        let failure = slow.open().await.unwrap().get(&target).await.err();
        assert_eq!(failure, Some(HttpFailure::TimedOut));

        let dead = api(&FakeApi::dead_url(), command.clone());
        let failure = dead.open().await.unwrap().get(&target).await.err();
        assert_eq!(failure, Some(HttpFailure::Unreachable));

        let missing = api(&hung.url, command).with_curl("/nonexistent/example-curl".into());
        let failure = missing.open().await.unwrap().get(&target).await.err();
        assert_eq!(failure, Some(HttpFailure::NotRun));
    }

    #[tokio::test]
    async fn a_non_json_body_is_unreadable_and_a_500_is_its_status() {
        let server = FakeApi::start(|seen| match seen.path() {
            "/html" => Canned::text(200, "<html>example-private-body</html>"),
            _ => Canned::json(
                500,
                json!({ "errors": [{ "detail": "example-private-body" }] }),
            ),
        })
        .await;
        let dir = tempfile::tempdir().unwrap();
        let api = api(&server.url, credential_script(dir.path(), "example-token"));
        let session = api.open().await.unwrap();

        let html = session.get(&Target::fixed("/html")).await.unwrap();
        assert_eq!(
            html.json::<serde_json::Value>().err(),
            Some(HttpFailure::Unreadable)
        );
        let failed = session.get(&Target::fixed("/failed")).await.unwrap();
        assert_eq!(failed.status, 500);
        assert_eq!(
            failed.json::<serde_json::Value>().err(),
            Some(HttpFailure::Status(500))
        );
    }

    #[tokio::test]
    async fn a_redirect_is_not_followed() {
        let elsewhere = FakeApi::start(|_| Canned::json(200, json!({}))).await;
        let location = format!("{}/stolen", elsewhere.url);
        let server = FakeApi::start(move |_| Canned::redirect(&location)).await;
        let dir = tempfile::tempdir().unwrap();
        let api = api(&server.url, credential_script(dir.path(), "example-token"));

        let reply = api
            .open()
            .await
            .unwrap()
            .get(&Target::fixed("/api/states"))
            .await
            .unwrap();

        assert_eq!(reply.status, 302);
        assert_eq!(server.seen().len(), 1);
        assert!(
            elsewhere.seen().is_empty(),
            "the token must not follow a redirect to another server"
        );
    }
}
