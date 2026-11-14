//! Direct controls for the Omabox systemd user service and its journal.

use std::path::PathBuf;
use std::process::Stdio;

use miette::Diagnostic;
use thiserror::Error;

use crate::spawn::Launch;

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

/// What systemd's `ActiveState` lets the CLI do with the user service.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum UnitState {
    /// `active`, `reloading`, `refreshing` or `activating`, including the wait before an automatic restart.
    Running,
    /// `failed`: ended by a fatal exit, the start limit or a stop that timed out, until a command clears it.
    Failed,
    /// `deactivating`: stopping after a stop request or the daemon's own exit; it can still end `failed`.
    Stopping,
    /// `inactive` or `maintenance`, which an unloaded unit also reports: no daemon process.
    Stopped,
}

/// Programs used to control and inspect the user service.
#[derive(Clone, Debug)]
pub struct ServiceCommands {
    systemctl: Launch,
    journalctl: Launch,
}

impl Default for ServiceCommands {
    fn default() -> Self {
        Self {
            systemctl: Launch::Program(PathBuf::from("systemctl")),
            journalctl: Launch::Program(PathBuf::from("journalctl")),
        }
    }
}

impl ServiceCommands {
    /// Run the given shell scripts in place of the real programs.
    ///
    /// This is the seam that keeps subprocess behavior deterministic in tests.
    /// Each script is passed to `/bin/sh` rather than executed, so writing one
    /// can never collide with a concurrent spawn.
    #[must_use]
    pub fn scripts(systemctl: impl Into<PathBuf>, journalctl: impl Into<PathBuf>) -> Self {
        Self {
            systemctl: Launch::Script(systemctl.into()),
            journalctl: Launch::Script(journalctl.into()),
        }
    }

    /// Return whether systemd currently considers the user service active.
    pub fn is_active(&self) -> Result<bool, ServiceError> {
        let status = self
            .systemctl
            .command()
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

    /// Return whether the user service is enabled at login.
    pub fn is_enabled(&self) -> Result<bool, ServiceError> {
        self.query_state("is-enabled", "systemctl is-enabled")
    }

    /// Read the user service's `ActiveState` from systemd.
    pub fn state(&self) -> Result<UnitState, ServiceError> {
        let output = self
            .systemctl
            .command()
            .args(["--user", "show", "--property=ActiveState", "--value", UNIT])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .output()
            .map_err(|source| ServiceError::StartCommand {
                command: "systemctl show",
                source,
            })?;
        status_result(output.status, "systemctl show")?;
        match String::from_utf8_lossy(&output.stdout).trim() {
            "active" | "reloading" | "refreshing" | "activating" => Ok(UnitState::Running),
            "failed" => Ok(UnitState::Failed),
            "deactivating" => Ok(UnitState::Stopping),
            "inactive" | "maintenance" => Ok(UnitState::Stopped),
            state => Err(ServiceError::UnknownState {
                state: state.to_owned(),
            }),
        }
    }

    /// Clear the user service's failed state and its start-limit counter.
    pub fn reset_failed(&self) -> Result<(), ServiceError> {
        let status = self
            .systemctl
            .command()
            .args(["--user", "reset-failed", UNIT])
            .status()
            .map_err(|source| ServiceError::StartCommand {
                command: "systemctl reset-failed",
                source,
            })?;
        status_result(status, "systemctl reset-failed")
    }

    /// Reload user service unit files after installation changes.
    pub fn daemon_reload(&self) -> Result<(), ServiceError> {
        let status = self
            .systemctl
            .command()
            .args(["--user", "daemon-reload"])
            .status()
            .map_err(|source| ServiceError::StartCommand {
                command: "systemctl daemon-reload",
                source,
            })?;
        status_result(status, "systemctl daemon-reload")
    }

    /// Run one direct systemctl operation.
    pub fn control(&self, action: ServiceAction) -> Result<(), ServiceError> {
        let mut command = self.systemctl.command();
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
        let status = self
            .journalctl
            .command()
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

    fn query_state(
        &self,
        argument: &'static str,
        command_name: &'static str,
    ) -> Result<bool, ServiceError> {
        let status = self
            .systemctl
            .command()
            .args(["--user", argument, "--quiet", UNIT])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map_err(|source| ServiceError::StartCommand {
                command: command_name,
                source,
            })?;
        match status.code() {
            Some(0) => Ok(true),
            Some(1 | 3 | 4) => Ok(false),
            Some(code) => Err(ServiceError::Unsuccessful {
                command: command_name,
                status: Some(code),
            }),
            None => Err(ServiceError::Terminated {
                command: command_name,
            }),
        }
    }
}

fn status_result(
    status: std::process::ExitStatus,
    command: &'static str,
) -> Result<(), ServiceError> {
    match status.code() {
        Some(0) => Ok(()),
        Some(code) => Err(ServiceError::Unsuccessful {
            command,
            status: Some(code),
        }),
        None => Err(ServiceError::Terminated { command }),
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

    /// systemd reported an `ActiveState` this version does not know.
    #[error("systemd reported the unknown service state `{state}`")]
    #[diagnostic(
        code(omabox::service::unknown_state),
        help("Update Omabox, or report this state if Omabox is current.")
    )]
    UnknownState {
        /// The trimmed state systemd printed.
        state: String,
    },
}

#[cfg(test)]
mod tests {
    use std::error::Error;
    use std::fs;
    use std::path::Path;

    use super::*;

    /// Record the arguments the caller passed, then exit with `exit`.
    ///
    /// The script is never given the executable bit: `ServiceCommands::scripts`
    /// reads it through `/bin/sh`, and a regression to a direct spawn fails
    /// with a permission error instead of racing.
    fn recording_script(
        directory: &Path,
        name: &str,
        output: &Path,
        exit: i32,
    ) -> Result<PathBuf, Box<dyn Error>> {
        let path = directory.join(name);
        fs::write(
            &path,
            format!(
                "printf '%s\\n' \"$@\" > '{}'\nexit {exit}\n",
                output.display()
            ),
        )?;
        Ok(path)
    }

    fn terminating_script(directory: &Path, name: &str) -> Result<PathBuf, Box<dyn Error>> {
        let path = directory.join(name);
        fs::write(&path, "kill -TERM $$\n")?;
        Ok(path)
    }

    #[test]
    fn service_and_log_commands_use_only_documented_arguments() -> Result<(), Box<dyn Error>> {
        let temporary = tempfile::TempDir::new()?;
        let systemctl_arguments = temporary.path().join("systemctl.args");
        let journalctl_arguments = temporary.path().join("journalctl.args");
        let systemctl = recording_script(temporary.path(), "systemctl", &systemctl_arguments, 0)?;
        let journalctl =
            recording_script(temporary.path(), "journalctl", &journalctl_arguments, 0)?;
        let commands = ServiceCommands::scripts(systemctl, journalctl);

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

        // The recording script prints nothing, which is not a known state.
        assert!(matches!(
            commands.state(),
            Err(ServiceError::UnknownState { state }) if state.is_empty()
        ));
        assert_eq!(
            fs::read_to_string(&systemctl_arguments)?,
            "--user\nshow\n--property=ActiveState\n--value\nomabox.service\n"
        );

        commands.reset_failed()?;
        assert_eq!(
            fs::read_to_string(&systemctl_arguments)?,
            "--user\nreset-failed\nomabox.service\n"
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
        let systemctl = recording_script(temporary.path(), "systemctl", &arguments, 3)?;
        let commands = ServiceCommands::scripts(systemctl, "/unused/journalctl");

        assert!(!commands.is_active()?);
        commands.control(ServiceAction::Status)?;
        Ok(())
    }

    #[test]
    fn state_maps_each_active_state() -> Result<(), Box<dyn Error>> {
        let temporary = tempfile::TempDir::new()?;
        let systemctl = temporary.path().join("systemctl");
        for (printed, expected) in [
            ("active", UnitState::Running),
            ("reloading", UnitState::Running),
            ("refreshing", UnitState::Running),
            ("activating", UnitState::Running),
            ("failed", UnitState::Failed),
            ("inactive", UnitState::Stopped),
            ("deactivating", UnitState::Stopping),
            ("maintenance", UnitState::Stopped),
        ] {
            fs::write(&systemctl, format!("printf '%s\\n' {printed}\n"))?;
            let commands = ServiceCommands::scripts(&systemctl, "/unused/journalctl");
            assert_eq!(commands.state()?, expected, "{printed}");
        }
        fs::write(&systemctl, "printf '%s\\n' bogus\n")?;
        let commands = ServiceCommands::scripts(&systemctl, "/unused/journalctl");
        assert!(matches!(
            commands.state(),
            Err(ServiceError::UnknownState { state }) if state == "bogus"
        ));
        Ok(())
    }

    #[test]
    fn signal_terminated_controls_have_a_distinct_error() -> Result<(), Box<dyn Error>> {
        let temporary = tempfile::TempDir::new()?;
        let systemctl = terminating_script(temporary.path(), "systemctl")?;
        let journalctl = terminating_script(temporary.path(), "journalctl")?;
        let commands = ServiceCommands::scripts(systemctl, journalctl);

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
