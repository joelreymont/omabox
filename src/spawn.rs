//! How a configured program becomes a `std::process::Command`.
//!
//! Tests stand in for `systemctl`, `omarchy`, and `secret-tool` with shell
//! scripts they write themselves. Executing such a script races with the rest
//! of a parallel test binary: `execve` reports `ETXTBSY` while any process
//! still holds a write descriptor on the file, and a concurrent spawn inherits
//! that descriptor until its own `execve` closes it. A script is therefore
//! passed to the shell as an argument, so it is read and never executed.

#[cfg(test)]
use std::path::Path;
use std::path::PathBuf;
use std::process::Command;

const SHELL: &str = "/bin/sh";

/// The program behind one external command.
#[derive(Clone, Debug)]
pub(crate) enum Launch {
    /// An installed executable, resolved as given or through `PATH`.
    Program(PathBuf),
    /// A shell script read by `/bin/sh`, never executed.
    Script(PathBuf),
}

impl Launch {
    /// Start building the command that runs this program.
    pub(crate) fn command(&self) -> Command {
        match self {
            Self::Program(path) => Command::new(path),
            Self::Script(path) => {
                let mut command = Command::new(SHELL);
                command.arg(path);
                command
            }
        }
    }

    /// The file this program runs from, so a test can rewrite its own script.
    #[cfg(test)]
    pub(crate) fn path(&self) -> &Path {
        match self {
            Self::Program(path) | Self::Script(path) => path,
        }
    }
}
