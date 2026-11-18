use std::{
    fs,
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

use super::{BelowFloor, OwnerFloor, OwnerLink};
use crate::{
    coordinator_id::CoordinatorId, failover::OwnerEpoch, protocol::RuntimeEventKind,
    runtime::decode_coordinator_event, serialized_spawn::SerializedSpawn,
};

const FIRST: &str = "11111111-1111-4111-8111-111111111111";
const SECOND: &str = "44444444-4444-4444-8444-444444444444";
const CHILD_FLOORS: &str = "AGENT_TEST_OWNER_FLOORS";
const CHILD_START: &str = "AGENT_TEST_OWNER_FLOOR_START";
const CHILD_LAST: u64 = 160;

fn coordinator(id: &str) -> CoordinatorId {
    id.parse().unwrap()
}

fn at(id: &str, epoch: u64) -> OwnerLink {
    OwnerLink::Identified {
        coordinator: coordinator(id),
        epoch: Some(OwnerEpoch::new(epoch).unwrap()),
    }
}

fn floors(root: &Path) -> (OwnerFloor, PathBuf) {
    let directory = root.join("data").join("beep-boop-owner-floors");
    (
        OwnerFloor {
            directory: directory.clone(),
        },
        directory,
    )
}

fn refused(result: anyhow::Result<()>) -> String {
    let error = result.expect_err("the link must be refused");
    assert!(error.is::<BelowFloor>(), "{error:#}");
    error.to_string()
}

#[test]
fn a_lower_epoch_is_refused_and_leaves_the_floor_byte_identical() {
    let root = tempfile::tempdir().unwrap();
    let (floor, directory) = floors(root.path());
    let file = directory.join(FIRST);
    floor.admit(at(FIRST, 5)).unwrap();
    assert_eq!(fs::read(&file).unwrap(), b"5\n");
    let message = refused(floor.admit(at(FIRST, 4)));
    assert!(
        message.contains(FIRST) && message.contains("epoch 4") && message.contains("epoch 5"),
        "{message}"
    );
    assert_eq!(fs::read(&file).unwrap(), b"5\n");
    floor.admit(at(FIRST, 5)).unwrap();
    floor.check(at(FIRST, 5)).unwrap();
    floor.admit(at(FIRST, 6)).unwrap();
    assert_eq!(fs::read(&file).unwrap(), b"6\n");
    refused(floor.check(at(FIRST, 5)));
}

#[test]
fn no_epoch_is_served_without_a_file_until_the_coordinator_has_a_floor() {
    let root = tempfile::tempdir().unwrap();
    let (floor, directory) = floors(root.path());
    let unfenced = OwnerLink::Identified {
        coordinator: coordinator(FIRST),
        epoch: None,
    };
    floor.admit(unfenced).unwrap();
    floor.check(unfenced).unwrap();
    assert!(
        !directory.exists(),
        "a link without an epoch created a file"
    );
    floor.admit(at(FIRST, 3)).unwrap();
    let message = refused(floor.admit(unfenced));
    assert!(
        message.contains(FIRST) && message.contains("epoch 3"),
        "{message}"
    );
    refused(floor.check(unfenced));
}

#[test]
fn two_coordinators_have_independent_floors() {
    let root = tempfile::tempdir().unwrap();
    let (floor, directory) = floors(root.path());
    floor.admit(at(FIRST, 5)).unwrap();
    floor.admit(at(SECOND, 1)).unwrap();
    refused(floor.admit(at(FIRST, 4)));
    floor.admit(at(SECOND, 2)).unwrap();
    floor
        .admit(OwnerLink::new(Some(coordinator(SECOND)), None))
        .unwrap_err();
    assert_eq!(fs::read(directory.join(FIRST)).unwrap(), b"5\n");
    assert_eq!(fs::read(directory.join(SECOND)).unwrap(), b"2\n");
}

#[test]
fn raising_never_lowers_a_floor_and_refuses_nothing() {
    let root = tempfile::tempdir().unwrap();
    let (floor, directory) = floors(root.path());
    floor.admit(at(FIRST, 5)).unwrap();
    floor
        .raise(coordinator(FIRST), OwnerEpoch::new(7).unwrap())
        .unwrap();
    floor
        .raise(coordinator(FIRST), OwnerEpoch::new(3).unwrap())
        .unwrap();
    assert_eq!(fs::read(directory.join(FIRST)).unwrap(), b"7\n");
    refused(floor.check(at(FIRST, 5)));
    floor.check(at(FIRST, 7)).unwrap();
}

#[test]
fn an_older_coordinator_is_served_only_by_a_host_without_floors() {
    let frame = br#"{"type":"worker_ready","connection_id":"7"}"#;
    let RuntimeEventKind::WorkerReady {
        coordinator_id,
        owner_epoch,
        ..
    } = decode_coordinator_event(frame).unwrap()
    else {
        panic!("an older coordinator's ready frame must decode");
    };
    let link = OwnerLink::new(coordinator_id, owner_epoch);
    assert_eq!(link, OwnerLink::Unidentified);
    let root = tempfile::tempdir().unwrap();
    let (floor, directory) = floors(root.path());
    floor.admit(link).unwrap();
    assert!(!directory.exists());
    floor.admit(at(SECOND, 2)).unwrap();
    let message = refused(floor.admit(link));
    assert!(
        message.contains(SECOND) && message.contains("epoch 2"),
        "{message}"
    );
    refused(floor.check(link));
}

#[test]
fn a_crash_before_the_rename_leaves_the_old_floor_in_force() {
    let root = tempfile::tempdir().unwrap();
    let (floor, directory) = floors(root.path());
    let unfenced = OwnerLink::new(Some(coordinator(FIRST)), None);
    fs::create_dir_all(&directory).unwrap();
    fs::write(directory.join(format!("{FIRST}.tmp")), "9").unwrap();
    floor.admit(unfenced).unwrap();
    floor.admit(at(FIRST, 5)).unwrap();
    fs::write(directory.join(format!("{FIRST}.tmp")), "9").unwrap();
    refused(floor.admit(at(FIRST, 4)));
    refused(floor.admit(unfenced));
    assert_eq!(fs::read(directory.join(FIRST)).unwrap(), b"5\n");
    floor.admit(at(FIRST, 7)).unwrap();
    assert_eq!(fs::read(directory.join(FIRST)).unwrap(), b"7\n");
    assert!(!directory.join(format!("{FIRST}.tmp")).exists());
}

#[test]
fn a_damaged_floor_refuses_every_epoch_and_is_left_alone() {
    let root = tempfile::tempdir().unwrap();
    let (floor, directory) = floors(root.path());
    fs::create_dir_all(&directory).unwrap();
    fs::write(directory.join(FIRST), "five\n").unwrap();
    for link in [
        at(FIRST, 100),
        OwnerLink::new(Some(coordinator(FIRST)), None),
    ] {
        let error = floor.admit(link).unwrap_err();
        assert!(
            error.to_string().contains("is not an owner floor"),
            "{error:#}"
        );
    }
    assert_eq!(fs::read(directory.join(FIRST)).unwrap(), b"five\n");
}

#[test]
fn concurrent_admits_from_two_processes_never_lower_the_floor() {
    let root = tempfile::tempdir().unwrap();
    let (_, directory) = floors(root.path());
    let test = std::env::current_exe().unwrap();
    let children: Vec<_> = [1, 2]
        .into_iter()
        .map(|start| {
            Command::new(&test)
                .args([
                    "--exact",
                    "owner_floor::tests::admit_every_other_epoch_in_a_child_process",
                    "--include-ignored",
                    "--test-threads=1",
                ])
                .env(CHILD_FLOORS, &directory)
                .env(CHILD_START, start.to_string())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn_serialized()
                .unwrap()
        })
        .collect();
    for child in children {
        let output = child.wait_with_output().unwrap();
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(
            output.status.success() && stdout.contains("1 passed"),
            "{stdout}{}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    assert_eq!(
        fs::read_to_string(directory.join(FIRST)).unwrap(),
        format!("{CHILD_LAST}\n")
    );
}

#[test]
#[ignore = "the child process of concurrent_admits_from_two_processes_never_lower_the_floor"]
fn admit_every_other_epoch_in_a_child_process() {
    let (Some(directory), Ok(start)) = (std::env::var_os(CHILD_FLOORS), std::env::var(CHILD_START))
    else {
        return;
    };
    let floor = OwnerFloor {
        directory: directory.into(),
    };
    for epoch in (start.parse::<u64>().unwrap()..=CHILD_LAST).step_by(2) {
        match floor.admit(at(FIRST, epoch)) {
            Ok(()) => assert!(
                floor.read(coordinator(FIRST)).unwrap() >= Some(OwnerEpoch::new(epoch).unwrap()),
                "the floor fell below admitted epoch {epoch}"
            ),
            Err(error) => assert!(error.is::<BelowFloor>(), "{error:#}"),
        }
    }
}
