//! Filesystem helpers shared by the crate's unit tests and its integration
//! tests.
//!
//! `src/lib.rs` pulls this file in under `cfg(test)` and `tests/dropbox_fake.rs`
//! declares it as an ordinary test module, so both see one definition.

use std::error::Error;
use std::fs::{Permissions, set_permissions};
use std::io;
use std::os::unix::fs::PermissionsExt as _;
use std::path::Path;

/// Remove every permission bit and prove this process is actually denied.
///
/// A user whose access is never enforced would turn every test that depends on
/// a denied path into a silent pass, so the denial is verified here instead.
pub fn deny_all_access(path: &Path) -> Result<(), Box<dyn Error>> {
    set_permissions(path, Permissions::from_mode(0o000))?;
    if std::fs::File::open(path).is_ok() || std::fs::read_dir(path).is_ok() {
        return Err(
            io::Error::other("test requires a user whose access permissions are enforced").into(),
        );
    }
    Ok(())
}

/// Restore owner access so a denied path can be read and removed again.
pub fn allow_owner_access(path: &Path) -> Result<(), Box<dyn Error>> {
    set_permissions(path, Permissions::from_mode(0o700))?;
    Ok(())
}
