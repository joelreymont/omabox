#![deny(clippy::expect_used, clippy::panic, clippy::unwrap_used)]

use miette::Diagnostic;
use thiserror::Error;

/// An error reported by Omabox.
#[derive(Debug, Diagnostic, Error)]
#[non_exhaustive]
pub enum Error {
    /// The requested functionality is not part of the current build.
    #[error("the requested Omabox functionality is not available")]
    #[diagnostic(
        code(omabox::functionality_unavailable),
        help("this build currently provides only the Omabox package foundation")
    )]
    FunctionalityUnavailable,
}

/// A result returned by Omabox library operations.
pub type Result<T> = std::result::Result<T, Error>;
