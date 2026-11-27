//! Waits for a child while reading its piped output.

use std::{
    io::{self, Read},
    process::{Child, Output},
    sync::{Arc, Mutex, mpsc},
    thread,
    time::{Duration, Instant},
};

/// How long a killed child's pipes get to reach end of file.
const CLOSE_GRACE: Duration = Duration::from_secs(1);

/// Waits up to `limit` for `child` to exit and close its piped stdout and
/// stderr, reading both meanwhile, and kills it at the deadline. A pipe can
/// hold as little as 512 bytes on a loaded macOS host, so a child that writes
/// more than that blocks until someone reads it; reading only after exit
/// would wait out the limit. Returns what was read and whether the child
/// finished by itself: exited, with both pipes closed, within the limit.
pub fn wait_with_output_until(mut child: Child, limit: Duration) -> (Output, bool) {
    let deadline = Instant::now() + limit;
    let stdout = Drain::start(child.stdout.take());
    let stderr = Drain::start(child.stderr.take());
    let (status, exited) = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break (status, true);
        }
        if Instant::now() >= deadline {
            // The child can exit between the check and the kill.
            let _ = child.kill();
            break (child.wait().unwrap(), false);
        }
        thread::sleep(Duration::from_millis(10));
    };
    // A descendant that inherited a pipe can hold it open after the child is
    // gone, so end of file is awaited only until the deadline.
    let until = deadline.max(Instant::now() + CLOSE_GRACE);
    let closed = [stdout.closed_by(until), stderr.closed_by(until)];
    let output = Output {
        status,
        stdout: stdout.bytes(),
        stderr: stderr.bytes(),
    };
    let mut finished = exited;
    for closed in closed {
        match closed {
            Ok(closed) => finished &= closed,
            Err(error) => panic!(
                "Could not read the child's output: {error}: {}",
                String::from_utf8_lossy(&output.stderr)
            ),
        }
    }
    (output, finished)
}

/// One pipe read on its own thread. The bytes are kept as they arrive, so a
/// pipe that never closes still shows what it carried.
struct Drain {
    bytes: Arc<Mutex<Vec<u8>>>,
    end: mpsc::Receiver<io::Result<()>>,
}

impl Drain {
    fn start(pipe: Option<impl Read + Send + 'static>) -> Self {
        let bytes = Arc::new(Mutex::new(Vec::new()));
        let (ended, end) = mpsc::channel();
        match pipe {
            Some(mut pipe) => {
                let kept = Arc::clone(&bytes);
                thread::spawn(move || {
                    let mut chunk = [0; 8192];
                    let result = loop {
                        match pipe.read(&mut chunk) {
                            Ok(0) => break Ok(()),
                            Ok(count) => kept.lock().unwrap().extend_from_slice(&chunk[..count]),
                            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                            Err(error) => break Err(error),
                        }
                    };
                    let _ = ended.send(result);
                });
            }
            None => {
                let _ = ended.send(Ok(()));
            }
        }
        Self { bytes, end }
    }

    /// Whether the pipe reached end of file by `until`.
    fn closed_by(&self, until: Instant) -> io::Result<bool> {
        match self
            .end
            .recv_timeout(until.saturating_duration_since(Instant::now()))
        {
            Ok(result) => result.map(|()| true),
            Err(_) => Ok(false),
        }
    }

    fn bytes(&self) -> Vec<u8> {
        self.bytes.lock().unwrap().clone()
    }
}
