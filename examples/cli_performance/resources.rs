use std::time::Duration;

use anyhow::{Context, Result, ensure};
use serde::Serialize;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    Cli,
    Coordinator,
    Runtime,
}

#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum PeakKind {
    #[cfg(target_os = "macos")]
    LifetimeMaxPhysFootprint,
    #[cfg(target_os = "linux")]
    VmHwm,
}

#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Since {
    WindowOpen,
    ProcessStart,
}

#[derive(Clone, Copy, Debug)]
pub struct Reading {
    cpu: Duration,
    resident_bytes: u64,
    peak_bytes: u64,
}

#[derive(Clone, Debug, Serialize)]
pub struct Process {
    pub role: Role,
    pub pid: i32,
    pub cpu_ms: f64,
    pub resident_bytes: u64,
    pub peak_bytes: u64,
    pub peak_kind: PeakKind,
    pub since: Since,
}

pub struct Window(Vec<(Role, i32, Reading)>);

impl Window {
    pub fn open(processes: &[(Role, i32)]) -> Result<Self> {
        processes
            .iter()
            .map(|(role, pid)| Ok((*role, *pid, read(*pid)?)))
            .collect::<Result<_>>()
            .map(Self)
    }

    pub fn close(self, processes: &[(Role, i32)]) -> Result<Vec<Process>> {
        processes
            .iter()
            .map(|(role, pid)| {
                let closed = read(*pid)?;
                let opened = self.0.iter().find(|(opened, ..)| opened == role);
                let (cpu, since) = match opened {
                    Some((_, opened_pid, opened)) => {
                        ensure!(
                            opened_pid == pid,
                            "{role:?} changed from pid {opened_pid} to {pid} inside the window"
                        );
                        let cpu = closed.cpu.checked_sub(opened.cpu).with_context(|| {
                            format!("{role:?} CPU time decreased inside the window")
                        })?;
                        (cpu, Since::WindowOpen)
                    }
                    None => (closed.cpu, Since::ProcessStart),
                };
                Ok(Process {
                    role: *role,
                    pid: *pid,
                    cpu_ms: cpu.as_secs_f64() * 1000.0,
                    resident_bytes: closed.resident_bytes,
                    peak_bytes: closed.peak_bytes,
                    peak_kind: PEAK_KIND,
                    since,
                })
            })
            .collect()
    }
}

#[cfg(target_os = "macos")]
pub const PEAK_KIND: PeakKind = PeakKind::LifetimeMaxPhysFootprint;
#[cfg(target_os = "linux")]
pub const PEAK_KIND: PeakKind = PeakKind::VmHwm;

impl PeakKind {
    pub fn label(self) -> &'static str {
        match self {
            #[cfg(target_os = "macos")]
            Self::LifetimeMaxPhysFootprint => "peak footprint",
            #[cfg(target_os = "linux")]
            Self::VmHwm => "peak resident",
        }
    }
}

#[cfg(target_os = "macos")]
fn read(pid: i32) -> Result<Reading> {
    #[repr(C)]
    struct Timebase {
        numer: u32,
        denom: u32,
    }
    unsafe extern "C" {
        fn mach_timebase_info(info: *mut Timebase) -> libc::c_int;
    }
    let mut timebase = Timebase { numer: 0, denom: 0 };
    ensure!(
        unsafe { mach_timebase_info(&raw mut timebase) } == 0 && timebase.denom != 0,
        "The Mach timebase is unavailable"
    );
    let mut info = unsafe { std::mem::zeroed::<libc::rusage_info_v4>() };
    ensure!(
        unsafe {
            libc::proc_pid_rusage(
                pid,
                libc::RUSAGE_INFO_V4,
                (&raw mut info).cast::<libc::rusage_info_t>(),
            )
        } == 0,
        "Could not read process {pid}: {}",
        std::io::Error::last_os_error()
    );
    let ticks = u128::from(info.ri_user_time) + u128::from(info.ri_system_time);
    let nanoseconds = ticks * u128::from(timebase.numer) / u128::from(timebase.denom);
    Ok(Reading {
        cpu: Duration::from_nanos(u64::try_from(nanoseconds)?),
        resident_bytes: info.ri_resident_size,
        peak_bytes: info.ri_lifetime_max_phys_footprint,
    })
}

#[cfg(target_os = "linux")]
fn read(pid: i32) -> Result<Reading> {
    let mut clock: libc::clockid_t = 0;
    let error = unsafe { libc::clock_getcpuclockid(pid, &raw mut clock) };
    ensure!(
        error == 0,
        "Could not find the CPU clock of process {pid}: {}",
        std::io::Error::from_raw_os_error(error)
    );
    let mut time = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    ensure!(
        unsafe { libc::clock_gettime(clock, &raw mut time) } == 0,
        "Could not read the CPU clock of process {pid}: {}",
        std::io::Error::last_os_error()
    );
    let status = std::fs::read_to_string(format!("/proc/{pid}/status"))?;
    let kilobytes = |field: &str| -> Result<u64> {
        let line = status
            .lines()
            .find_map(|line| line.strip_prefix(field))
            .with_context(|| format!("Process {pid} has no {field}"))?;
        Ok(line.trim().trim_end_matches("kB").trim().parse::<u64>()? * 1024)
    };
    Ok(Reading {
        cpu: Duration::new(u64::try_from(time.tv_sec)?, u32::try_from(time.tv_nsec)?),
        resident_bytes: kilobytes("VmRSS:")?,
        peak_bytes: kilobytes("VmHWM:")?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_busy_child_reports_its_cpu_time_and_resident_memory() {
        let mut child = std::process::Command::new("/bin/sh")
            .args(["-c", "while :; do :; done"])
            .spawn()
            .unwrap();
        let pid = i32::try_from(child.id()).unwrap();
        let window = Window::open(&[(Role::Coordinator, pid)]).unwrap();
        std::thread::sleep(Duration::from_millis(300));
        let measured = window.close(&[(Role::Coordinator, pid), (Role::Cli, pid)]);
        child.kill().unwrap();
        child.wait().unwrap();
        let measured = measured.unwrap();
        assert!(measured[0].cpu_ms >= 150.0, "{measured:?}");
        assert!(measured[0].resident_bytes > 0);
        assert!(matches!(measured[0].since, Since::WindowOpen));
        assert!(measured[1].cpu_ms >= measured[0].cpu_ms);
        assert!(matches!(measured[1].since, Since::ProcessStart));
    }
}
