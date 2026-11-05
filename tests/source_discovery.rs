use std::{fs, os::unix::fs::PermissionsExt, path::Path};

use agent_cli::{
    background::{self, BackgroundRequest, BackgroundResponse},
    protocol::SourceState,
    sources::{SourceConfig, SourceCoverage, SourceKey},
};

const EMPTY_MAILBOX: &str = r#"{"status":"executed","fields":{"status":"ok","messages":[],"has_more":false,"failures":[]},"coverage":{"status":"complete","next_cursor":null}}"#;

fn install_switchboard(bin: &Path) -> std::path::PathBuf {
    let registry = bin.join("registry.json");
    let switchboard = bin.join("switchboard");
    fs::write(
        &switchboard,
        format!(
            "#!/bin/sh\ncase \"$1\" in\n  ns) [ -f '{}' ] || exit 1; exec cat '{}' ;;\n  google.mail.search) printf '%s' '{EMPTY_MAILBOX}' ;;\n  *) exit 1 ;;\nesac\n",
            registry.display(),
            registry.display(),
        ),
    )
    .unwrap();
    fs::set_permissions(&switchboard, fs::Permissions::from_mode(0o700)).unwrap();
    registry
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
        let admitted = SourceState {
            source: read.batch.source,
            checkpoint: read.batch.checkpoint,
            coverage: read.batch.coverage,
            checked_at: 0,
        };
        match states
            .iter_mut()
            .find(|state| state.source == admitted.source)
        {
            Some(state) => *state = admitted,
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
    let bin = tempfile::tempdir().unwrap();
    let registry = install_switchboard(bin.path());
    let path = std::env::join_paths(
        std::iter::once(bin.path().to_owned())
            .chain(std::env::split_paths(&std::env::var_os("PATH").unwrap())),
    )
    .unwrap();
    // This test binary has one test, so no other thread reads the environment.
    unsafe { std::env::set_var("PATH", path) };
    let config = [SourceConfig::Google {
        enabled: true,
        namespaces: None,
    }];
    let mut states = Vec::new();

    for _ in 0..2 {
        round(&config, &mut states).await;
        assert_eq!(states.len(), 1);
        assert!(matches!(
            state(&states, "discovery").unwrap().coverage,
            SourceCoverage::Unavailable { .. }
        ));
    }

    fs::write(
        &registry,
        r#"{"namespaces":[{"id":"google.example","provider":"google"}]}"#,
    )
    .unwrap();
    round(&config, &mut states).await;
    let account = state(&states, "google.example").unwrap();
    assert_eq!(account.coverage, SourceCoverage::Complete);
    assert!(account.checkpoint.is_some());
    assert!(
        state(&states, "discovery").is_none(),
        "A successful discovery must retire the failed discovery placeholder: {states:?}"
    );
}
