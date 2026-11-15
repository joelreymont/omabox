//! Direct controls for the Omabox systemd user service and its journal.

use std::io::Write;
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
    /// `active`, `reloading` or `refreshing`: the daemon reached readiness.
    Running,
    /// `activating`, including the wait before an automatic restart: no daemon has reached readiness yet.
    Starting,
    /// `failed`: ended by a fatal exit, the start limit or a stop that timed out, until a command clears it.
    Failed,
    /// `deactivating`: stopping after a stop request or the daemon's own exit; it can still end `failed`.
    Stopping,
    /// `inactive` or `maintenance`, which an unloaded unit also reports: no daemon process.
    Stopped,
}

/// What a command wants from the user service; [`ServiceCommands::drive`] reaches it.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ServiceGoal {
    /// Clear a failed state and the start limit, then start.
    Start,
    /// Clear a failed state and the start limit, then restart.
    Restart,
    /// After a change that may fix a fatal cause, start a failed unit; stop a stopping unit and look again first; leave a running, starting or stopped unit.
    Recover,
    /// Stop a running, starting or stopping unit and leave no failed state.
    Halt,
    /// Stop a unit that can hold the instance lock (running, starting or stopping); leave a failed state for a later Recover.
    Release,
    /// Start again a unit observed running or starting before a change; leave any other, or one never observed.
    Restore(Option<UnitState>),
}

/// What [`ServiceCommands::drive`] observed and did.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Driven {
    /// The state observed before any change; `None` for Start, Restart and Restore, which observe nothing.
    pub first: Option<UnitState>,
    /// Whether the goal ran start or restart.
    pub launched: bool,
}

/// Where [`ServiceCommands::drive`] is on the way to its goal.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Phase {
    /// Nothing observed or changed yet.
    Begin,
    /// The state observed before any change.
    Seen(UnitState),
    /// A stop ran; the state is not yet observed again.
    AfterStop,
    /// The state observed after a stop.
    Settled(UnitState),
    /// A failed state and the start limit were cleared.
    Cleared,
    /// Start or restart ran.
    Launched,
}

/// The one systemctl operation [`ServiceCommands::drive`] runs next.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Step {
    /// Read the unit's state.
    Observe,
    /// Stop the unit.
    Stop,
    /// Clear a failed state and the start limit.
    Clear,
    /// Start or restart the unit.
    Launch(ServiceAction),
    /// The goal is reached.
    Done,
}

/// What the step [`ServiceCommands::drive`] just ran did.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Outcome {
    /// The unit's state was read.
    Observed(UnitState),
    /// The unit was stopped.
    Stopped,
    /// A failed state and the start limit were cleared.
    Cleared,
    /// Start or restart ran.
    Launched,
}

/// The phase after `outcome`: the first observation is Seen, any later one Settled.
const fn advance(phase: Phase, outcome: Outcome) -> Phase {
    match (phase, outcome) {
        (Phase::Begin, Outcome::Observed(state)) => Phase::Seen(state),
        (_, Outcome::Observed(state)) => Phase::Settled(state),
        (_, Outcome::Stopped) => Phase::AfterStop,
        (_, Outcome::Cleared) => Phase::Cleared,
        (_, Outcome::Launched) => Phase::Launched,
    }
}

/// Choose the next step toward `goal` from `phase`.
const fn next(goal: ServiceGoal, phase: Phase) -> Step {
    use ServiceGoal::{Halt, Recover, Release, Restart, Restore, Start};
    use UnitState::{Failed, Running, Starting, Stopping};
    match (goal, phase) {
        (Start | Restart, Phase::Begin) => Step::Clear,
        (Start, Phase::Cleared) => Step::Launch(ServiceAction::Start),
        (Restart, Phase::Cleared) => Step::Launch(ServiceAction::Restart),
        (Recover | Halt | Release, Phase::Begin) => Step::Observe,
        (Recover, Phase::Seen(Failed)) => Step::Clear,
        (Recover, Phase::Seen(Stopping)) => Step::Stop,
        (Recover, Phase::AfterStop) => Step::Observe,
        (Recover, Phase::Settled(Failed)) => Step::Clear,
        (Recover, Phase::Cleared) => Step::Launch(ServiceAction::Start),
        (Halt, Phase::Seen(Running | Starting | Stopping)) => Step::Stop,
        (Halt, Phase::Seen(Failed)) => Step::Clear,
        (Halt, Phase::AfterStop) => Step::Observe,
        (Halt, Phase::Settled(Failed)) => Step::Clear,
        (Release, Phase::Seen(Running | Starting | Stopping)) => Step::Stop,
        (Restore(Some(Running | Starting)), Phase::Begin) => Step::Clear,
        (Restore(_), Phase::Cleared) => Step::Launch(ServiceAction::Start),
        _ => Step::Done,
    }
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
            "active" | "reloading" | "refreshing" => Ok(UnitState::Running),
            "activating" => Ok(UnitState::Starting),
            "failed" => Ok(UnitState::Failed),
            "deactivating" => Ok(UnitState::Stopping),
            "inactive" | "maintenance" => Ok(UnitState::Stopped),
            state => Err(ServiceError::UnknownState {
                state: state.to_owned(),
            }),
        }
    }

    /// Run `verb` (stop or reset-failed) on the unit.
    ///
    /// An unloaded unit has nothing to stop or clear: systemd unloads a disabled,
    /// stopped unit and then refuses both, so that refusal succeeds once systemd
    /// confirms the unit is not loaded. Only that refusal's message is dropped;
    /// anything else systemctl writes to stderr goes to `errors`.
    fn settle(
        &self,
        verb: &'static str,
        command: &'static str,
        errors: &mut impl Write,
    ) -> Result<(), ServiceError> {
        let output = self
            .systemctl
            .command()
            .args(["--user", verb, UNIT])
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .output()
            .map_err(|source| ServiceError::StartCommand { command, source })?;
        match status_result(output.status, command) {
            // Checked after the failure: systemd can unload the unit between two calls.
            Err(ServiceError::Unsuccessful { .. }) if self.unloaded() => Ok(()),
            result => {
                // The result still reports a failure if stderr is gone.
                let _ = errors.write_all(&output.stderr);
                result
            }
        }
    }

    /// Return whether systemd confirms the unit is not loaded.
    ///
    /// `list-units` lists only loaded units and loads none, unlike `show`.
    fn unloaded(&self) -> bool {
        self.systemctl
            .command()
            .args([
                "--user",
                "list-units",
                "--all",
                "--plain",
                "--no-legend",
                UNIT,
            ])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .output()
            .is_ok_and(|output| {
                output.status.success() && String::from_utf8_lossy(&output.stdout).trim().is_empty()
            })
    }

    /// Drive the user service toward `goal` through systemctl, observing its
    /// state only where the goal's steps, tabled at `next`, call for it.
    pub fn drive(&self, goal: ServiceGoal) -> Result<Driven, ServiceError> {
        let mut phase = Phase::Begin;
        let mut driven = Driven {
            first: None,
            launched: false,
        };
        loop {
            let outcome = match next(goal, phase) {
                Step::Observe => {
                    let state = self.state()?;
                    if phase == Phase::Begin {
                        driven.first = Some(state);
                    }
                    Outcome::Observed(state)
                }
                Step::Stop => {
                    self.settle("stop", "systemctl stop", &mut std::io::stderr())?;
                    Outcome::Stopped
                }
                Step::Clear => {
                    self.settle(
                        "reset-failed",
                        "systemctl reset-failed",
                        &mut std::io::stderr(),
                    )?;
                    Outcome::Cleared
                }
                Step::Launch(action) => {
                    self.control(action)?;
                    driven.launched = true;
                    Outcome::Launched
                }
                Step::Done => return Ok(driven),
            };
            phase = advance(phase, outcome);
        }
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
    fn control(&self, action: ServiceAction) -> Result<(), ServiceError> {
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

    /// Start the service automatically at login.
    pub fn enable(&self) -> Result<(), ServiceError> {
        self.control(ServiceAction::Enable)
    }

    /// Stop starting the service automatically at login.
    pub fn disable(&self) -> Result<(), ServiceError> {
        self.control(ServiceAction::Disable)
    }

    /// Show systemd's current service status.
    pub fn status(&self) -> Result<(), ServiceError> {
        self.control(ServiceAction::Status)
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

        commands.settle("reset-failed", "systemctl reset-failed", &mut Vec::new())?;
        assert_eq!(
            fs::read_to_string(&systemctl_arguments)?,
            "--user\nreset-failed\nomabox.service\n"
        );

        commands.settle("stop", "systemctl stop", &mut Vec::new())?;
        assert_eq!(
            fs::read_to_string(&systemctl_arguments)?,
            "--user\nstop\nomabox.service\n"
        );

        // A failed reset-failed asks list-units whether the unit is loaded.
        fs::write(
            temporary.path().join("systemctl"),
            format!(
                "printf '%s\\n' \"$@\" > '{}'\nexit 1\n",
                systemctl_arguments.display()
            ),
        )?;
        assert!(
            commands
                .settle("reset-failed", "systemctl reset-failed", &mut Vec::new())
                .is_err()
        );
        assert_eq!(
            fs::read_to_string(&systemctl_arguments)?,
            "--user\nlist-units\n--all\n--plain\n--no-legend\nomabox.service\n"
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
            ("activating", UnitState::Starting),
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

    /// Walk `next` from Begin for `goal`, observing `first`, then `settled` after a stop.
    fn walk(goal: ServiceGoal, first: UnitState, settled: UnitState) -> Vec<Step> {
        let mut phase = Phase::Begin;
        let mut steps = Vec::new();
        while steps.len() < 8 {
            let step = next(goal, phase);
            steps.push(step);
            let outcome = match step {
                Step::Observe if phase == Phase::Begin => Outcome::Observed(first),
                Step::Observe => Outcome::Observed(settled),
                Step::Stop => Outcome::Stopped,
                Step::Clear => Outcome::Cleared,
                Step::Launch(_) => Outcome::Launched,
                Step::Done => break,
            };
            phase = advance(phase, outcome);
        }
        steps
    }

    #[test]
    fn every_goal_takes_its_steps_from_each_state() {
        use ServiceGoal::{Halt, Recover, Release, Restart, Restore, Start};
        use Step::{Clear, Done, Launch, Observe, Stop};
        use UnitState::{Failed, Running, Starting, Stopped, Stopping};
        const START: Step = Launch(ServiceAction::Start);
        const RESTART: Step = Launch(ServiceAction::Restart);
        const STOP_LOOK: &[Step] = &[Observe, Stop, Observe, Done];
        const STOP_CLEAR: &[Step] = &[Observe, Stop, Observe, Clear, Done];
        /// Goal, first observed, observed after a stop, steps; `None` matches any state.
        type Walk = (
            ServiceGoal,
            Option<UnitState>,
            Option<UnitState>,
            &'static [Step],
        );
        let table: &[Walk] = &[
            (Start, None, None, &[Clear, START, Done]),
            (Restart, None, None, &[Clear, RESTART, Done]),
            (Recover, Some(Running), None, &[Observe, Done]),
            (Recover, Some(Starting), None, &[Observe, Done]),
            (Recover, Some(Failed), None, &[Observe, Clear, START, Done]),
            (Recover, Some(Stopped), None, &[Observe, Done]),
            (Recover, Some(Stopping), Some(Running), STOP_LOOK),
            (Recover, Some(Stopping), Some(Starting), STOP_LOOK),
            (
                Recover,
                Some(Stopping),
                Some(Failed),
                &[Observe, Stop, Observe, Clear, START, Done],
            ),
            (Recover, Some(Stopping), Some(Stopping), STOP_LOOK),
            (Recover, Some(Stopping), Some(Stopped), STOP_LOOK),
            (Halt, Some(Running), Some(Running), STOP_LOOK),
            (Halt, Some(Running), Some(Starting), STOP_LOOK),
            (Halt, Some(Running), Some(Failed), STOP_CLEAR),
            (Halt, Some(Running), Some(Stopping), STOP_LOOK),
            (Halt, Some(Running), Some(Stopped), STOP_LOOK),
            (Halt, Some(Starting), Some(Running), STOP_LOOK),
            (Halt, Some(Starting), Some(Starting), STOP_LOOK),
            (Halt, Some(Starting), Some(Failed), STOP_CLEAR),
            (Halt, Some(Starting), Some(Stopping), STOP_LOOK),
            (Halt, Some(Starting), Some(Stopped), STOP_LOOK),
            (Halt, Some(Stopping), Some(Running), STOP_LOOK),
            (Halt, Some(Stopping), Some(Starting), STOP_LOOK),
            (Halt, Some(Stopping), Some(Failed), STOP_CLEAR),
            (Halt, Some(Stopping), Some(Stopping), STOP_LOOK),
            (Halt, Some(Stopping), Some(Stopped), STOP_LOOK),
            (Halt, Some(Failed), None, &[Observe, Clear, Done]),
            (Halt, Some(Stopped), None, &[Observe, Done]),
            (Release, Some(Running), None, &[Observe, Stop, Done]),
            (Release, Some(Starting), None, &[Observe, Stop, Done]),
            (Release, Some(Stopping), None, &[Observe, Stop, Done]),
            (Release, Some(Failed), None, &[Observe, Done]),
            (Release, Some(Stopped), None, &[Observe, Done]),
            (Restore(None), None, None, &[Done]),
            (Restore(Some(Running)), None, None, &[Clear, START, Done]),
            (Restore(Some(Starting)), None, None, &[Clear, START, Done]),
            (Restore(Some(Failed)), None, None, &[Done]),
            (Restore(Some(Stopping)), None, None, &[Done]),
            (Restore(Some(Stopped)), None, None, &[Done]),
        ];
        let states = [Running, Starting, Failed, Stopping, Stopped];
        let goals = [Start, Restart, Recover, Halt, Release, Restore(None)]
            .into_iter()
            .chain(states.map(|state| Restore(Some(state))));
        for goal in goals {
            for first in states {
                for settled in states {
                    let case = format!("{goal:?} seeing {first:?} settling {settled:?}");
                    let rows: Vec<_> = table
                        .iter()
                        .filter(|(g, f, s, _)| {
                            *g == goal
                                && f.is_none_or(|f| f == first)
                                && s.is_none_or(|s| s == settled)
                        })
                        .collect();
                    assert_eq!(rows.len(), 1, "{case}: one expected walk");
                    let steps = walk(goal, first, settled);
                    assert_eq!(steps, rows[0].3, "{case}");
                    assert_eq!(steps.last(), Some(&Done), "{case}: ends at Done");
                }
            }
        }
    }

    /// A systemctl that logs each verb to `log` and answers each `show` with
    /// the next of `states`, then exits 0.
    fn scripted_systemctl(
        directory: &Path,
        log: &Path,
        states: &[&str],
    ) -> Result<PathBuf, Box<dyn Error>> {
        let queue = directory.join("states");
        fs::write(
            &queue,
            states.iter().map(|s| format!("{s}\n")).collect::<String>(),
        )?;
        let path = directory.join("systemctl");
        let (log, queue) = (log.display(), queue.display());
        fs::write(
            &path,
            format!(
                "printf '%s\\n' \"$2\" >> '{log}'\n\
                 if [ \"$2\" = show ]; then\n\
                 head -n 1 '{queue}'\n\
                 tail -n +2 '{queue}' > '{queue}.next'\n\
                 mv '{queue}.next' '{queue}'\n\
                 fi\n"
            ),
        )?;
        Ok(path)
    }

    #[test]
    fn drive_runs_each_step_through_systemctl() -> Result<(), Box<dyn Error>> {
        let temporary = tempfile::TempDir::new()?;
        let log = temporary.path().join("systemctl.log");

        let systemctl = scripted_systemctl(temporary.path(), &log, &["active", "failed"])?;
        let commands = ServiceCommands::scripts(systemctl, "/unused/journalctl");
        assert_eq!(
            commands.drive(ServiceGoal::Halt)?,
            Driven {
                first: Some(UnitState::Running),
                launched: false
            }
        );
        assert_eq!(
            fs::read_to_string(&log)?,
            "show\nstop\nshow\nreset-failed\n"
        );

        fs::remove_file(&log)?;
        let systemctl = scripted_systemctl(temporary.path(), &log, &["failed"])?;
        let commands = ServiceCommands::scripts(systemctl, "/unused/journalctl");
        assert_eq!(
            commands.drive(ServiceGoal::Recover)?,
            Driven {
                first: Some(UnitState::Failed),
                launched: true
            }
        );
        assert_eq!(fs::read_to_string(&log)?, "show\nreset-failed\nstart\n");
        Ok(())
    }

    #[test]
    fn settling_an_unloaded_unit_succeeds() -> Result<(), Box<dyn Error>> {
        let temporary = tempfile::TempDir::new()?;
        let systemctl = temporary.path().join("systemctl");
        let script = |verb: &str, refusal: &str, listed: &str| {
            format!(
                "if [ \"$2\" = {verb} ]; then echo '{refusal}' >&2; exit 1; fi\nprintf '{listed}'\n"
            )
        };

        for (verb, command) in [
            ("stop", "systemctl stop"),
            ("reset-failed", "systemctl reset-failed"),
        ] {
            fs::write(
                &systemctl,
                script(verb, "Unit omabox.service not loaded.", ""),
            )?;
            let commands = ServiceCommands::scripts(&systemctl, "/unused/journalctl");
            let mut errors = Vec::new();
            commands.settle(verb, command, &mut errors)?;
            assert!(errors.is_empty(), "{verb}: no message for an unloaded unit");

            let refusal = format!("Failed to {verb} unit omabox.service: Access denied");
            fs::write(
                &systemctl,
                script(
                    verb,
                    &refusal,
                    "omabox.service loaded inactive dead Omabox\\n",
                ),
            )?;
            let commands = ServiceCommands::scripts(&systemctl, "/unused/journalctl");
            let mut errors = Vec::new();
            assert!(
                matches!(
                    commands.settle(verb, command, &mut errors),
                    Err(ServiceError::Unsuccessful { command: c, .. }) if c == command
                ),
                "{verb}"
            );
            assert_eq!(String::from_utf8(errors)?, format!("{refusal}\n"), "{verb}");

            let warning = "Warning: The unit file, source configuration file or drop-ins of \
                           omabox.service changed on disk.";
            fs::write(&systemctl, format!("echo '{warning}' >&2\n"))?;
            let commands = ServiceCommands::scripts(&systemctl, "/unused/journalctl");
            let mut errors = Vec::new();
            commands.settle(verb, command, &mut errors)?;
            assert_eq!(String::from_utf8(errors)?, format!("{warning}\n"), "{verb}");
        }
        Ok(())
    }

    #[test]
    fn a_failed_clear_stops_the_drive() -> Result<(), Box<dyn Error>> {
        let temporary = tempfile::TempDir::new()?;
        let log = temporary.path().join("systemctl.log");
        let systemctl = temporary.path().join("systemctl");
        let script = |listed: &str| {
            format!(
                "printf '%s\\n' \"$2\" >> '{}'\n\
                 case \"$2\" in\n\
                 reset-failed) exit 1;;\n\
                 list-units) printf '{listed}';;\n\
                 esac\n",
                log.display()
            )
        };

        fs::write(
            &systemctl,
            script("omabox.service loaded failed failed Omabox\\n"),
        )?;
        let commands = ServiceCommands::scripts(&systemctl, "/unused/journalctl");
        assert!(matches!(
            commands.drive(ServiceGoal::Start),
            Err(ServiceError::Unsuccessful {
                command: "systemctl reset-failed",
                ..
            })
        ));
        assert_eq!(fs::read_to_string(&log)?, "reset-failed\nlist-units\n");

        fs::remove_file(&log)?;
        fs::write(&systemctl, script(""))?;
        let commands = ServiceCommands::scripts(&systemctl, "/unused/journalctl");
        assert_eq!(
            commands.drive(ServiceGoal::Start)?,
            Driven {
                first: None,
                launched: true
            }
        );
        assert_eq!(
            fs::read_to_string(&log)?,
            "reset-failed\nlist-units\nstart\n"
        );

        // systemd can unload the unit between the observation and the stop.
        fs::remove_file(&log)?;
        let queue = temporary.path().join("states");
        fs::write(&queue, "active\ninactive\n")?;
        fs::write(
            &systemctl,
            format!(
                "printf '%s\\n' \"$2\" >> '{log}'\n\
                 case \"$2\" in\n\
                 show) head -n 1 '{queue}'; tail -n +2 '{queue}' > '{queue}.next'; mv '{queue}.next' '{queue}';;\n\
                 stop) exit 5;;\n\
                 esac\n",
                log = log.display(),
                queue = queue.display()
            ),
        )?;
        let commands = ServiceCommands::scripts(&systemctl, "/unused/journalctl");
        assert_eq!(
            commands.drive(ServiceGoal::Halt)?,
            Driven {
                first: Some(UnitState::Running),
                launched: false
            }
        );
        assert_eq!(fs::read_to_string(&log)?, "show\nstop\nlist-units\nshow\n");
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
