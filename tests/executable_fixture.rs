//! Linux refuses to execute a file that any process holds open for writing.
#![cfg(target_os = "linux")]

#[path = "fixtures/executable.rs"]
mod executable_fixture;

use std::{
    os::unix::process::CommandExt,
    process::Command,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::Duration,
};

use executable_fixture::write_executable;

#[test]
fn fixture_runs_while_sibling_spawns_hold_inherited_descriptors() {
    let stop = Arc::new(AtomicBool::new(false));
    let siblings: Vec<_> = (0..8)
        .map(|_| {
            let stop = stop.clone();
            thread::spawn(move || {
                while !stop.load(Ordering::Relaxed) {
                    let mut sibling = Command::new("true");
                    // A loaded scheduler can leave a sibling test's child
                    // between fork and exec. The pause makes that window
                    // reliable without changing what the child inherits.
                    unsafe {
                        sibling.pre_exec(|| {
                            thread::sleep(Duration::from_millis(5));
                            Ok(())
                        });
                    }
                    sibling.status().unwrap();
                }
            })
        })
        .collect();
    let directory = tempfile::tempdir().unwrap();
    let failure = (0..500).find_map(|attempt| {
        let program = directory.path().join(format!("fixture-{attempt}"));
        write_executable(&program, "#!/bin/sh\nexit 0\n");
        match Command::new(&program).status() {
            Ok(status) if status.success() => None,
            outcome => Some(format!("attempt {attempt}: {outcome:?}")),
        }
    });
    stop.store(true, Ordering::Relaxed);
    for sibling in siblings {
        sibling.join().unwrap();
    }
    assert_eq!(failure, None);
}
