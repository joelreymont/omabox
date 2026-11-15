//! Removal of temporaries that a killed or failed Omabox process left behind.

use std::fmt;
use std::fs;
use std::io;
use std::os::unix::ffi::OsStrExt as _;
use std::path::{Path, PathBuf};

use rustix::io::Errno;
use rustix::process::{Pid, test_kill_process};

/// A directory the sweep could not read, or a stale temporary it could not
/// inspect or remove; the next sweep tries again.
#[derive(Debug)]
pub struct Leftover {
    pub path: PathBuf,
    /// "read a directory" or "remove a stale temporary".
    pub operation: &'static str,
    pub source: io::Error,
}

impl fmt::Display for Leftover {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "could not {} `{}`: {}",
            self.operation,
            self.path.display(),
            self.source
        )
    }
}

/// One line for each stale temporary a command left in place.
pub fn report(leftovers: &[Leftover]) -> String {
    leftovers
        .iter()
        .map(|leftover| format!("Left a stale temporary in place: {leftover}\n"))
        .collect()
}

const READ_DIRECTORY: &str = "read a directory";
const REMOVE_TEMPORARY: &str = "remove a stale temporary";

/// Remove each entry of `directory` named exactly `{prefix}{pid}.{seq}{suffix}`
/// whose process no longer exists, and return what could not be removed.
///
/// A live PID keeps its entry whatever process now owns it, and a PID whose
/// liveness cannot be established is treated as live. Symlinks are never
/// followed: a matching symlink is unlinked, and a matching directory is
/// removed without following any symlink inside it. A missing directory holds
/// nothing to sweep. The sweep never fails: it continues past each directory
/// or entry it cannot read or remove and returns one `Leftover` for each.
pub(crate) fn sweep(directory: &Path, prefix: &[u8], suffix: &[u8]) -> Vec<Leftover> {
    let mut leftovers = Vec::new();
    let entries = match fs::read_dir(directory) {
        Ok(entries) => entries,
        Err(source) if source.kind() == io::ErrorKind::NotFound => return leftovers,
        Err(source) => {
            leftovers.push(leftover(directory, READ_DIRECTORY, source));
            return leftovers;
        }
    };
    for entry in entries {
        let entry = match entry {
            Ok(entry) => entry,
            Err(source) => {
                leftovers.push(leftover(directory, READ_DIRECTORY, source));
                continue;
            }
        };
        let name = entry.file_name();
        let Some(pid) = owner(name.as_bytes(), prefix, suffix) else {
            continue;
        };
        if is_dead(pid)
            && let Err(failure) = remove(&entry.path())
        {
            leftovers.push(failure);
        }
    }
    leftovers
}

/// The PID in a name of the form `{prefix}{pid}.{seq}{suffix}`, where both
/// numbers are canonical decimals and the PID is positive.
fn owner(name: &[u8], prefix: &[u8], suffix: &[u8]) -> Option<Pid> {
    let token = name.strip_prefix(prefix)?.strip_suffix(suffix)?;
    let mut parts = token.split(|&byte| byte == b'.');
    let (pid, seq) = (parts.next()?, parts.next()?);
    if parts.next().is_some() || !is_decimal(pid) || !is_decimal(seq) {
        return None;
    }
    std::str::from_utf8(seq).ok()?.parse::<u64>().ok()?;
    Pid::from_raw(std::str::from_utf8(pid).ok()?.parse::<i32>().ok()?)
}

fn is_decimal(digits: &[u8]) -> bool {
    match digits {
        [] => false,
        [b'0'] => true,
        [b'0', ..] => false,
        _ => digits.iter().all(u8::is_ascii_digit),
    }
}

/// `kill(pid, 0)` fails with ESRCH only when no such process exists; EPERM
/// and every other outcome leave the entry in place.
fn is_dead(pid: Pid) -> bool {
    matches!(test_kill_process(pid), Err(Errno::SRCH))
}

fn remove(path: &Path) -> Result<(), Leftover> {
    let removed = match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_dir() => fs::remove_dir_all(path),
        Ok(_) => fs::remove_file(path),
        Err(source) => Err(source),
    };
    match removed {
        Ok(()) => Ok(()),
        // A concurrent sweep removed it first.
        Err(source) if source.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(source) => Err(leftover(path, REMOVE_TEMPORARY, source)),
    }
}

fn leftover(path: &Path, operation: &'static str, source: io::Error) -> Leftover {
    Leftover {
        path: path.to_path_buf(),
        operation,
        source,
    }
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::io;
    use std::os::unix::fs::PermissionsExt as _;

    use super::{READ_DIRECTORY, sweep};

    #[test]
    fn unreadable_directory_is_one_leftover() -> Result<(), Box<dyn std::error::Error>> {
        // Root reads a directory whatever its mode.
        if rustix::process::geteuid().is_root() {
            return Ok(());
        }
        let temporary = tempfile::TempDir::new()?;
        let directory = temporary.path().join("unreadable");
        fs::create_dir(&directory)?;
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o300))?;
        let leftovers = sweep(&directory, b".omabox.install.", b"");
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))?;

        assert_eq!(leftovers.len(), 1, "{leftovers:?}");
        assert_eq!(leftovers[0].path, directory);
        assert_eq!(leftovers[0].operation, READ_DIRECTORY);
        assert_eq!(leftovers[0].source.kind(), io::ErrorKind::PermissionDenied);
        Ok(())
    }
}
