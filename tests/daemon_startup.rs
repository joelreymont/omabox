#![deny(clippy::expect_used, clippy::panic, clippy::unwrap_used)]

use std::error::Error;
use std::fs;
use std::io;
use std::os::unix::net::UnixDatagram;
use std::path::PathBuf;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::time::Duration;

use omabox::config::{Config, InstanceLock, LockError, XdgDirectories};
use omabox::journal::Journal;
use tempfile::TempDir;

struct ChildGuard {
    child: Option<Child>,
}

impl ChildGuard {
    fn spawn(command: &mut Command) -> io::Result<Self> {
        Ok(Self {
            child: Some(command.spawn()?),
        })
    }

    fn is_running(&mut self) -> io::Result<bool> {
        let Some(child) = &mut self.child else {
            return Err(io::Error::other("daemon child was already reaped"));
        };
        Ok(child.try_wait()?.is_none())
    }

    fn terminate(&mut self) -> io::Result<ExitStatus> {
        let Some(mut child) = self.child.take() else {
            return Err(io::Error::other("daemon child was already reaped"));
        };
        if let Some(status) = child.try_wait()? {
            return Ok(status);
        }
        child.kill()?;
        child.wait()
    }
}

impl Drop for ChildGuard {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

struct StartupFixture {
    _temporary: TempDir,
    config: Config,
    config_home: PathBuf,
    state_home: PathBuf,
    runtime: PathBuf,
    command_path: PathBuf,
    notify_path: PathBuf,
    notify: UnixDatagram,
}

impl StartupFixture {
    fn new() -> Result<Self, Box<dyn Error>> {
        let temporary = TempDir::new()?;
        let config_home = temporary.path().join("config");
        let state_home = temporary.path().join("state");
        let runtime = temporary.path().join("runtime");
        let command_path = temporary.path().join("empty-bin");
        let sync_root = temporary.path().join("Dropbox");
        fs::create_dir(&runtime)?;
        fs::create_dir(&command_path)?;
        fs::create_dir(&sync_root)?;
        let xdg = XdgDirectories::new(&config_home, &state_home)?;
        let config = Config::from_values(&xdg, &sync_root, "test-app-key")?;
        config.write_new()?;
        let notify_path = temporary.path().join("notify.sock");
        let notify = UnixDatagram::bind(&notify_path)?;
        Ok(Self {
            _temporary: temporary,
            config,
            config_home,
            state_home,
            runtime,
            command_path,
            notify_path,
            notify,
        })
    }

    fn command(&self) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_omaboxd"));
        command
            .env_clear()
            .env("XDG_CONFIG_HOME", &self.config_home)
            .env("XDG_STATE_HOME", &self.state_home)
            .env("XDG_RUNTIME_DIR", &self.runtime)
            .env("PATH", &self.command_path)
            .env("NOTIFY_SOCKET", &self.notify_path)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        command
    }

    fn receive(&self, timeout: Duration) -> io::Result<Vec<u8>> {
        self.notify.set_read_timeout(Some(timeout))?;
        let mut buffer = [0_u8; 32];
        let length = self.notify.recv(&mut buffer)?;
        Ok(buffer[..length].to_vec())
    }
}

#[test]
fn self_check_ignores_unavailable_configuration_and_prints_version() -> Result<(), Box<dyn Error>> {
    let output = Command::new(env!("CARGO_BIN_EXE_omaboxd"))
        .arg("--self-check")
        .env_clear()
        .env("XDG_CONFIG_HOME", "relative-and-invalid")
        .env("XDG_STATE_HOME", "relative-and-invalid")
        .output()?;
    assert!(output.status.success());
    assert_eq!(
        output.stdout,
        format!("omaboxd {}\n", env!("CARGO_PKG_VERSION")).as_bytes()
    );
    assert!(output.stderr.is_empty());
    Ok(())
}

#[test]
fn initialized_journal_and_held_lock_precede_readiness() -> Result<(), Box<dyn Error>> {
    let fixture = StartupFixture::new()?;
    let mut command = fixture.command();
    let mut child = ChildGuard::spawn(&mut command)?;

    assert_eq!(fixture.receive(Duration::from_secs(3))?, b"READY=1");
    assert!(matches!(
        InstanceLock::acquire(fixture.config.paths().lock_file()),
        Err(LockError::AlreadyRunning { .. })
    ));
    assert!(fixture.config.paths().journal_file().is_file());
    assert!(child.is_running()?);

    let _ = child.terminate()?;
    let _journal = Journal::open(fixture.config.paths().journal_file())?;
    Ok(())
}

#[test]
fn unavailable_root_never_sends_readiness() -> Result<(), Box<dyn Error>> {
    let fixture = StartupFixture::new()?;
    fs::remove_dir(fixture.config.sync_root())?;
    let mut command = fixture.command();
    let mut child = ChildGuard::spawn(&mut command)?;

    let receive = fixture.receive(Duration::from_secs(1));
    assert!(matches!(
        receive,
        Err(ref source)
            if matches!(
                source.kind(),
                io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
            )
    ));
    assert!(child.is_running()?);
    let _ = child.terminate()?;
    assert!(!fixture.config.paths().journal_file().exists());
    Ok(())
}
