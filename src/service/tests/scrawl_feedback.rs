use std::{
    fs,
    path::{Path, PathBuf},
    time::Duration,
};

use anyhow::Result;
use serde_json::Value;
use sha2::{Digest, Sha256};

use super::Running;
use crate::{
    runtime::Wire,
    scrawl_feedback::{
        BundleState, Destination, Dialer, Watcher, preview,
        test_bundles::{manifest, phone_timeline, write},
    },
    service::connect,
};

const COMPOSER_LOG: &str = "composer opened\ncomposer sent\n";

struct Harness(PathBuf);

#[async_trait::async_trait]
impl Dialer for Harness {
    async fn dial(&self, _: &Destination) -> Result<Wire> {
        Ok(Wire::local(connect(&self.0).await?))
    }
}

impl Running {
    fn dialer(&self) -> Harness {
        Harness(self.directory.path().to_owned())
    }

    fn coordinator_id(&self) -> String {
        fs::read_to_string(self.directory.path().join("coordinator-id")).unwrap()
    }

    fn delivered(&self) -> Vec<Value> {
        fs::read_to_string(self.directory.path().join("main-feedback.jsonl"))
            .map(|text| {
                text.lines()
                    .map(|line| serde_json::from_str(line).unwrap())
                    .collect()
            })
            .unwrap_or_default()
    }
}

#[tokio::test]
async fn pinned_phone_capture_reaches_the_coordinator_that_names_itself() {
    let service = Running::start().await;
    let captures = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    let mut watcher = Watcher::open(captures.path(), state.path()).unwrap();
    write(
        captures.path(),
        "phone.scrawl",
        &manifest("Watch the send button.", 2, Some("iphone")),
        Some(&phone_timeline(
            &service.coordinator_id().to_uppercase(),
            "The send button stays grey after I paste",
        )),
    );

    watcher.poll(&service.dialer()).await;

    let delivered = service.delivered();
    assert_eq!(delivered.len(), 1);
    let feedback = &delivered[0];
    assert_eq!(feedback["type"], "main_feedback");
    assert_eq!(
        feedback["description"],
        "The send button stays grey after I paste Narration: Watch the send button."
    );
    let attachments = feedback["attachments"].as_array().unwrap();
    let names: Vec<&str> = attachments
        .iter()
        .map(|attachment| attachment["name"].as_str().unwrap())
        .collect();
    assert_eq!(
        names,
        [
            "summary.md",
            "contact-sheet.png",
            "scrawl.json",
            "Composer.log",
            "frame-01.png",
            "frame-02.png",
            "recording.mp4"
        ]
    );
    assert_eq!(
        attachments[3]["sha256"],
        hex::encode(Sha256::digest(COMPOSER_LOG))
    );
    assert!(uuid::Uuid::parse_str(feedback["input_id"].as_str().unwrap()).is_ok());
    assert!(matches!(
        watcher.state("phone.scrawl"),
        Some(BundleState::Acknowledged)
    ));
    drop(watcher);
    service.stop().await;
}

#[tokio::test]
async fn another_coordinator_receives_nothing_after_identify() {
    let service = Running::start().await;
    let captures = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    let mut watcher = Watcher::open(captures.path(), state.path()).unwrap();
    let pinned = "6f9619ff-8b86-d011-b42d-00c04fc964ff";
    write(
        captures.path(),
        "phone.scrawl",
        &manifest("Watch the send button.", 1, Some("iphone")),
        Some(&phone_timeline(pinned, "The send button stays grey")),
    );
    let admitted = service.directory.path().join("admitted");
    let _ = fs::remove_file(&admitted);

    watcher.poll(&service.dialer()).await;

    assert!(
        !admitted.exists(),
        "No attachment or feedback reached the other coordinator"
    );
    assert!(service.delivered().is_empty());
    assert!(matches!(
        watcher.state("phone.scrawl"),
        Some(BundleState::Refused { reason }) if reason.contains(pinned)
    ));
    watcher.poll(&service.dialer()).await;
    assert!(!admitted.exists(), "A refused capture is never retried");
    drop(watcher);
    service.stop().await;
}

#[tokio::test]
async fn the_coordinator_records_the_description_the_dry_run_shows() {
    let service = Running::start().await;
    let captures = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    let mut watcher = Watcher::open(captures.path(), state.path()).unwrap();
    let narration = format!("--help me\n-- now\t{}", "naïve\n".repeat(700));
    write(
        captures.path(),
        "phone.scrawl",
        &manifest(&narration, 0, Some("iphone")),
        Some(&phone_timeline(
            &service.coordinator_id(),
            "-- -h the send button\n  stays grey",
        )),
    );
    let shown = serde_json::to_value(preview(captures.path()).unwrap().remove(0)).unwrap();

    watcher.poll(&service.dialer()).await;

    let delivered = service.delivered();
    assert_eq!(delivered.len(), 1);
    let description = delivered[0]["description"].as_str().unwrap();
    assert_eq!(description, shown["description"]);
    assert!(
        description
            .starts_with("-- -h the send button stays grey Narration: --help me -- now naïve")
    );
    assert!(description.len() <= 4096, "{} bytes", description.len());
    assert!(matches!(
        watcher.state("phone.scrawl"),
        Some(BundleState::Acknowledged)
    ));
    drop(watcher);
    service.stop().await;
}

#[tokio::test]
async fn a_rejected_submit_is_refused_and_never_resent() {
    let service = Running::start().await;
    let captures = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    fs::write(service.directory.path().join("reject-feedback"), "").unwrap();
    let mut watcher = Watcher::open(captures.path(), state.path()).unwrap();
    write(
        captures.path(),
        "mac.scrawl",
        &manifest("Look at this panel.", 1, None),
        None,
    );

    watcher.poll(&service.dialer()).await;
    assert!(matches!(
        watcher.state("mac.scrawl"),
        Some(BundleState::Refused { reason }) if reason == "Invented: feedback is paused here"
    ));
    drop(watcher);

    let mut restarted = Watcher::open(captures.path(), state.path()).unwrap();
    restarted.poll(&service.dialer()).await;
    assert_eq!(service.delivered().len(), 1);
    assert!(matches!(
        restarted.state("mac.scrawl"),
        Some(BundleState::Refused { .. })
    ));
    drop(restarted);
    service.stop().await;
}

#[tokio::test]
async fn acknowledged_feedback_is_not_sent_again_after_restart() {
    let service = Running::start().await;
    let captures = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    let mut watcher = Watcher::open(captures.path(), state.path()).unwrap();
    write(
        captures.path(),
        "mac.scrawl",
        &manifest("Look at this panel.", 1, None),
        None,
    );
    watcher.poll(&service.dialer()).await;
    assert_eq!(service.delivered().len(), 1);
    drop(watcher);

    let mut restarted = Watcher::open(captures.path(), state.path()).unwrap();
    restarted.poll(&service.dialer()).await;
    restarted.poll(&service.dialer()).await;
    assert_eq!(service.delivered().len(), 1);
    assert!(matches!(
        restarted.state("mac.scrawl"),
        Some(BundleState::Acknowledged)
    ));
    drop(restarted);
    service.stop().await;
}

#[tokio::test]
async fn unconfirmed_feedback_is_resent_identically_after_restart() {
    let service = Running::start().await;
    let captures = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    let unconfirmed = service.directory.path().join("unconfirmed-feedback");
    fs::write(&unconfirmed, "").unwrap();
    let mut watcher = Watcher::open(captures.path(), state.path()).unwrap();
    write(
        captures.path(),
        "phone.scrawl",
        &manifest("Watch the send button.", 1, Some("iphone")),
        Some(&phone_timeline(
            &service.coordinator_id(),
            "The send button stays grey",
        )),
    );
    watcher.poll(&service.dialer()).await;
    assert!(matches!(
        watcher.state("phone.scrawl"),
        Some(BundleState::Submitted { .. })
    ));
    drop(watcher);
    fs::remove_file(&unconfirmed).unwrap();

    let mut restarted = Watcher::open(captures.path(), state.path()).unwrap();
    restarted.poll(&service.dialer()).await;

    let delivered = service.delivered();
    assert_eq!(delivered.len(), 2);
    assert_eq!(delivered[0], delivered[1]);
    assert!(matches!(
        restarted.state("phone.scrawl"),
        Some(BundleState::Acknowledged)
    ));
    drop(restarted);
    service.stop().await;
}

fn age_submission(state: &Path, bundle: &str, by: Duration) {
    let path = state.join("scrawl-feedback.json");
    let mut ledger: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    let submitted_at = &mut ledger[bundle]["submitted_at_ms"];
    *submitted_at = (submitted_at.as_u64().unwrap() - by.as_millis() as u64).into();
    fs::write(&path, ledger.to_string()).unwrap();
}

async fn submit_unconfirmed(service: &Running, captures: &Path, state: &Path) {
    fs::write(service.directory.path().join("unconfirmed-feedback"), "").unwrap();
    let mut watcher = Watcher::open(captures, state).unwrap();
    write(
        captures,
        "mac.scrawl",
        &manifest("Look at this panel.", 1, None),
        None,
    );
    watcher.poll(&service.dialer()).await;
    assert!(matches!(
        watcher.state("mac.scrawl"),
        Some(BundleState::Submitted { .. })
    ));
}

#[tokio::test]
async fn feedback_unconfirmed_for_a_day_is_refused_once_its_uploads_expire() {
    let service = Running::start().await;
    let captures = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    submit_unconfirmed(&service, captures.path(), state.path()).await;
    age_submission(
        state.path(),
        "mac.scrawl",
        Duration::from_secs(25 * 60 * 60),
    );

    let mut restarted = Watcher::open(captures.path(), state.path()).unwrap();
    let notices = restarted.poll(&service.dialer()).await;

    assert!(matches!(
        restarted.state("mac.scrawl"),
        Some(BundleState::Refused { reason }) if reason.contains("24 hours")
    ));
    assert_eq!(
        notices
            .iter()
            .filter(|notice| notice.contains("mac.scrawl"))
            .count(),
        1,
        "{notices:?}"
    );
    assert_eq!(service.delivered().len(), 2);
    drop(restarted);

    let mut again = Watcher::open(captures.path(), state.path()).unwrap();
    assert!(again.poll(&service.dialer()).await.is_empty());
    assert_eq!(
        service.delivered().len(),
        2,
        "A refused capture is never resent"
    );
    drop(again);
    service.stop().await;
}

#[tokio::test]
async fn feedback_confirmed_after_a_day_still_counts_as_acknowledged() {
    let service = Running::start().await;
    let captures = tempfile::tempdir().unwrap();
    let state = tempfile::tempdir().unwrap();
    submit_unconfirmed(&service, captures.path(), state.path()).await;
    age_submission(
        state.path(),
        "mac.scrawl",
        Duration::from_secs(25 * 60 * 60),
    );
    fs::remove_file(service.directory.path().join("unconfirmed-feedback")).unwrap();

    let mut restarted = Watcher::open(captures.path(), state.path()).unwrap();
    restarted.poll(&service.dialer()).await;

    assert!(matches!(
        restarted.state("mac.scrawl"),
        Some(BundleState::Acknowledged)
    ));
    drop(restarted);
    service.stop().await;
}
