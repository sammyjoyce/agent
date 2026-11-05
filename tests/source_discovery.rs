use std::{fs, os::unix::fs::PermissionsExt};

use agent_cli::{
    background::{self, BackgroundRequest, BackgroundResponse},
    protocol::SourceState,
    sources::{SourceConfig, SourceCoverage, SourceKey},
};

const GOOGLE: [SourceConfig; 1] = [SourceConfig::Google {
    enabled: true,
    namespaces: None,
}];
const ACCOUNT_NAMED_DISCOVERY: &str = r#"{"namespaces":[{"id":"discovery","provider":"google"}]}"#;
const EMPTY_MAILBOX: &str = r#"{"status":"executed","fields":{"status":"ok","messages":[],"has_more":false,"failures":[]},"coverage":{"status":"complete","next_cursor":null}}"#;

/// Tests take turns because each one points PATH at its own fake switchboard.
static SWITCHBOARD: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

struct Switchboard {
    bin: tempfile::TempDir,
}

impl Switchboard {
    fn install() -> Self {
        let bin = tempfile::tempdir().unwrap();
        let registry = bin.path().join("registry.json");
        let mail_fails = bin.path().join("mail-fails");
        let switchboard = bin.path().join("switchboard");
        fs::write(
            &switchboard,
            format!(
                "#!/bin/sh\ncase \"$1\" in\n  ns) [ -f '{}' ] || exit 1; exec cat '{}' ;;\n  google.mail.search) [ -f '{}' ] && exit 1; printf '%s' '{EMPTY_MAILBOX}' ;;\n  *) exit 1 ;;\nesac\n",
                registry.display(),
                registry.display(),
                mail_fails.display(),
            ),
        )
        .unwrap();
        fs::set_permissions(&switchboard, fs::Permissions::from_mode(0o700)).unwrap();
        let path = std::env::join_paths(
            std::iter::once(bin.path().to_owned())
                .chain(std::env::split_paths(&std::env::var_os("PATH").unwrap())),
        )
        .unwrap();
        // Callers hold SWITCHBOARD, so no other thread reads the environment.
        unsafe { std::env::set_var("PATH", path) };
        Self { bin }
    }

    fn list(&self, registry: &str) {
        fs::write(self.bin.path().join("registry.json"), registry).unwrap();
    }

    fn fail_mail_reads(&self, fails: bool) {
        let flag = self.bin.path().join("mail-fails");
        if fails {
            fs::write(flag, "").unwrap();
        } else {
            fs::remove_file(flag).unwrap();
        }
    }
}

async fn round(config: &[SourceConfig], states: &mut Vec<SourceState>) {
    let BackgroundResponse::Sources {
        reads,
        retired,
        cursor,
    } = background::execute(BackgroundRequest::PollSources {
        sources: config.to_vec(),
        states: states.clone(),
        cursor: None,
    })
    .await
    .unwrap()
    else {
        panic!("Source polling returned another background response");
    };
    assert!(cursor.is_none(), "The fixture has one account page at most");
    for read in reads {
        let batch = read.batch;
        let previous = states.iter().position(|state| state.source == batch.source);
        let retained = previous.and_then(|index| states[index].checkpoint.clone());
        // Mirrors SourceJournal.admit: only a complete read replaces the checkpoint.
        let checkpoint = match batch.coverage {
            SourceCoverage::Complete | SourceCoverage::More => batch.checkpoint.or(retained),
            _ => retained,
        };
        let admitted = SourceState {
            source: batch.source,
            checkpoint,
            coverage: batch.coverage,
            checked_at: 0,
        };
        match previous {
            Some(index) => states[index] = admitted,
            None => states.push(admitted),
        }
    }
    states.retain(|state| !retired.contains(&state.source));
}

fn state<'a>(states: &'a [SourceState], account: &str) -> Option<&'a SourceState> {
    states.iter().find(|state| {
        state.source
            == SourceKey {
                provider: "google".into(),
                account: account.into(),
            }
    })
}

#[tokio::test]
async fn successful_discovery_retires_the_failed_discovery_placeholder() {
    let _turn = SWITCHBOARD.lock().await;
    let switchboard = Switchboard::install();
    let mut states = Vec::new();

    for _ in 0..2 {
        round(&GOOGLE, &mut states).await;
        assert_eq!(states.len(), 1);
        assert!(matches!(
            state(&states, "discovery").unwrap().coverage,
            SourceCoverage::Unavailable { .. }
        ));
    }

    switchboard.list(r#"{"namespaces":[{"id":"google.example","provider":"google"}]}"#);
    round(&GOOGLE, &mut states).await;
    let account = state(&states, "google.example").unwrap();
    assert_eq!(account.coverage, SourceCoverage::Complete);
    assert!(account.checkpoint.is_some());
    assert!(
        state(&states, "discovery").is_none(),
        "A successful discovery must retire the failed discovery placeholder: {states:?}"
    );
}

#[tokio::test]
async fn an_account_named_discovery_keeps_its_checkpoint_across_rounds() {
    let _turn = SWITCHBOARD.lock().await;
    let switchboard = Switchboard::install();
    switchboard.list(ACCOUNT_NAMED_DISCOVERY);
    let mut states = Vec::new();

    for round_number in 1..=3 {
        round(&GOOGLE, &mut states).await;
        let account = state(&states, "discovery")
            .unwrap_or_else(|| panic!("Round {round_number} deleted the account's state"));
        assert_eq!(account.coverage, SourceCoverage::Complete);
        assert!(account.checkpoint.is_some());
    }
}

#[tokio::test]
async fn an_account_named_discovery_reads_unavailable_while_its_reads_fail() {
    let _turn = SWITCHBOARD.lock().await;
    let switchboard = Switchboard::install();
    switchboard.list(ACCOUNT_NAMED_DISCOVERY);
    switchboard.fail_mail_reads(true);
    let mut states = Vec::new();

    for round_number in 1..=3 {
        round(&GOOGLE, &mut states).await;
        let account = state(&states, "discovery").unwrap_or_else(|| {
            panic!("Round {round_number} hid a failing account that never read")
        });
        assert!(matches!(
            account.coverage,
            SourceCoverage::Unavailable { .. }
        ));
    }

    switchboard.fail_mail_reads(false);
    round(&GOOGLE, &mut states).await;
    let checkpoint = state(&states, "discovery").unwrap().checkpoint.clone();
    assert!(checkpoint.is_some());

    switchboard.fail_mail_reads(true);
    for round_number in 1..=3 {
        round(&GOOGLE, &mut states).await;
        let account = state(&states, "discovery").unwrap_or_else(|| {
            panic!("Round {round_number} hid a failing account with a checkpoint")
        });
        assert!(matches!(
            account.coverage,
            SourceCoverage::Unavailable { .. }
        ));
        assert_eq!(account.checkpoint, checkpoint);
    }
}

#[tokio::test]
async fn an_account_named_discovery_keeps_its_checkpoint_after_leaving_discovery() {
    let _turn = SWITCHBOARD.lock().await;
    let switchboard = Switchboard::install();
    switchboard.list(ACCOUNT_NAMED_DISCOVERY);
    let mut states = Vec::new();
    round(&GOOGLE, &mut states).await;
    let checkpoint = state(&states, "discovery").unwrap().checkpoint.clone();
    assert!(checkpoint.is_some());

    switchboard.list(r#"{"namespaces":[]}"#);
    for round_number in 1..=2 {
        round(&GOOGLE, &mut states).await;
        let account = state(&states, "discovery").unwrap_or_else(|| {
            panic!("Round {round_number} deleted an undiscovered account's checkpoint")
        });
        assert_eq!(account.checkpoint, checkpoint);
    }
}
