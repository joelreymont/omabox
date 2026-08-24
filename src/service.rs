//! Direct controls for the Omabox systemd user service and its journal.

use std::path::PathBuf;
use std::process::{Command, Stdio};

use miette::Diagnostic;
use thiserror::Error;

const UNIT: &str = "omabox.service";

/// A supported systemd service operation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ServiceAction {
    /// Start the service now.
    Start,
    /// Stop the service now.
    Stop,
    /// Restart the service now.
    Restart,
    /// Start the service automatically at login.
    Enable,
    /// Stop starting the service automatically at login.
    Disable,
    /// Show systemd's current service status.
    Status,
}

impl ServiceAction {
    const fn argument(self) -> &'static str {
        match self {
            Self::Start => "start",
            Self::Stop => "stop",
            Self::Restart => "restart",
            Self::Enable => "enable",
            Self::Disable => "disable",
            Self::Status => "status",
        }
    }
}

/// Programs used to control and inspect the user service.
#[derive(Clone, Debug)]
pub struct ServiceCommands {
    systemctl: PathBuf,
    journalctl: PathBuf,
}

impl Default for ServiceCommands {
    fn default() -> Self {
        Self {
            systemctl: PathBuf::from("systemctl"),
            journalctl: PathBuf::from("journalctl"),
        }
    }
}

impl ServiceCommands {
    /// Construct commands with explicit program paths.
    ///
    /// This also keeps subprocess behavior deterministic in tests.
    #[must_use]
    pub fn new(systemctl: impl Into<PathBuf>, journalctl: impl Into<PathBuf>) -> Self {
        Self {
            systemctl: systemctl.into(),
            journalctl: journalctl.into(),
        }
    }

    /// Return whether systemd currently considers the user service active.
    pub fn is_active(&self) -> Result<bool, ServiceError> {
        let status = Command::new(&self.systemctl)
            .args(["--user", "is-active", "--quiet", UNIT])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map_err(|source| ServiceError::StartCommand {
                command: "systemctl is-active",
                source,
            })?;
        match status.code() {
            Some(0) => Ok(true),
            Some(3 | 4) => Ok(false),
            Some(code) => Err(ServiceError::Unsuccessful {
                command: "systemctl is-active",
                status: Some(code),
            }),
            None => Err(ServiceError::Terminated {
                command: "systemctl is-active",
            }),
        }
    }

    /// Run one direct systemctl operation.
    pub fn control(&self, action: ServiceAction) -> Result<(), ServiceError> {
        let mut command = Command::new(&self.systemctl);
        command.args(["--user", action.argument()]);
        if action == ServiceAction::Status {
            command.arg("--no-pager");
        }
        command.arg(UNIT);
        let status = command
            .status()
            .map_err(|source| ServiceError::StartCommand {
                command: "systemctl",
                source,
            })?;
        match status.code() {
            Some(0) => Ok(()),
            Some(3) if action == ServiceAction::Status => Ok(()),
            Some(code) => Err(ServiceError::Unsuccessful {
                command: "systemctl",
                status: Some(code),
            }),
            None => Err(ServiceError::Terminated {
                command: "systemctl",
            }),
        }
    }

    /// Show recent logs from the Omabox user service.
    pub fn logs(&self) -> Result<(), ServiceError> {
        let status = Command::new(&self.journalctl)
            .args(["--user-unit", UNIT, "--no-pager", "--lines", "200"])
            .status()
            .map_err(|source| ServiceError::StartCommand {
                command: "journalctl",
                source,
            })?;
        match status.code() {
            Some(0) => Ok(()),
            Some(code) => Err(ServiceError::Unsuccessful {
                command: "journalctl",
                status: Some(code),
            }),
            None => Err(ServiceError::Terminated {
                command: "journalctl",
            }),
        }
    }
}

/// A typed failure to inspect or control the systemd user service.
#[derive(Debug, Diagnostic, Error)]
#[non_exhaustive]
pub enum ServiceError {
    /// A system command could not be started.
    #[error("could not run `{command}`")]
    #[diagnostic(
        code(omabox::service::start_command),
        help("Ensure systemd user services and the system journal are available, then retry.")
    )]
    StartCommand {
        /// Stable command description without arguments or user paths.
        command: &'static str,
        /// Underlying process error.
        #[source]
        source: std::io::Error,
    },

    /// A command was terminated by a signal.
    #[error("`{command}` was terminated before it reported a result")]
    #[diagnostic(
        code(omabox::service::terminated),
        help("Retry the command; inspect the user session if it happens repeatedly.")
    )]
    Terminated {
        /// Stable command description.
        command: &'static str,
    },

    /// A command reported failure.
    #[error("`{command}` failed with status {status:?}")]
    #[diagnostic(
        code(omabox::service::unsuccessful),
        help("Review the command output and `omabox logs`, then retry.")
    )]
    Unsuccessful {
        /// Stable command description.
        command: &'static str,
        /// Exit status, or `None` when terminated by a signal.
        status: Option<i32>,
    },
}

#[cfg(test)]
mod tests {
    use std::error::Error;
    use std::fs;
    use std::os::unix::fs::PermissionsExt as _;
    use std::path::Path;

    use super::*;

    fn fake_command(
        directory: &Path,
        name: &str,
        output: &Path,
        exit: i32,
    ) -> Result<PathBuf, Box<dyn Error>> {
        let path = directory.join(name);
        fs::write(
            &path,
            format!(
                "#!/bin/sh\nprintf '%s\\n' \"$@\" > '{}'\nexit {exit}\n",
                output.display()
            ),
        )?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700))?;
        Ok(path)
    }

    fn terminating_command(directory: &Path, name: &str) -> Result<PathBuf, Box<dyn Error>> {
        let path = directory.join(name);
        fs::write(&path, "#!/bin/sh\nkill -TERM $$\n")?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700))?;
        Ok(path)
    }

    #[test]
    fn service_and_log_commands_use_only_documented_arguments() -> Result<(), Box<dyn Error>> {
        let temporary = tempfile::TempDir::new()?;
        let systemctl_arguments = temporary.path().join("systemctl.args");
        let journalctl_arguments = temporary.path().join("journalctl.args");
        let systemctl = fake_command(temporary.path(), "systemctl", &systemctl_arguments, 0)?;
        let journalctl = fake_command(temporary.path(), "journalctl", &journalctl_arguments, 0)?;
        let commands = ServiceCommands::new(systemctl, journalctl);

        assert!(commands.is_active()?);
        assert_eq!(
            fs::read_to_string(&systemctl_arguments)?,
            "--user\nis-active\n--quiet\nomabox.service\n"
        );

        commands.control(ServiceAction::Restart)?;
        assert_eq!(
            fs::read_to_string(&systemctl_arguments)?,
            "--user\nrestart\nomabox.service\n"
        );

        commands.logs()?;
        assert_eq!(
            fs::read_to_string(&journalctl_arguments)?,
            "--user-unit\nomabox.service\n--no-pager\n--lines\n200\n"
        );
        Ok(())
    }

    #[test]
    fn inactive_is_a_state_instead_of_an_error() -> Result<(), Box<dyn Error>> {
        let temporary = tempfile::TempDir::new()?;
        let arguments = temporary.path().join("systemctl.args");
        let systemctl = fake_command(temporary.path(), "systemctl", &arguments, 3)?;
        let commands = ServiceCommands::new(systemctl, "/unused/journalctl");

        assert!(!commands.is_active()?);
        commands.control(ServiceAction::Status)?;
        Ok(())
    }

    #[test]
    fn signal_terminated_controls_have_a_distinct_error() -> Result<(), Box<dyn Error>> {
        let temporary = tempfile::TempDir::new()?;
        let systemctl = terminating_command(temporary.path(), "systemctl")?;
        let journalctl = terminating_command(temporary.path(), "journalctl")?;
        let commands = ServiceCommands::new(systemctl, journalctl);

        assert!(matches!(
            commands.control(ServiceAction::Start),
            Err(ServiceError::Terminated {
                command: "systemctl"
            })
        ));
        assert!(matches!(
            commands.logs(),
            Err(ServiceError::Terminated {
                command: "journalctl"
            })
        ));
        Ok(())
    }
}
