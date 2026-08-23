#![deny(clippy::expect_used, clippy::panic, clippy::unwrap_used)]

use miette::Diagnostic;
use thiserror::Error;

pub mod config;
pub mod model;
pub mod planner;

/// An error reported by Omabox.
#[derive(Debug, Diagnostic, Error)]
#[non_exhaustive]
pub enum Error {
    /// Configuration could not be loaded or prepared.
    #[error(transparent)]
    #[diagnostic(transparent)]
    Config(#[from] config::ConfigError),

    /// The daemon's single-instance lock could not be acquired.
    #[error(transparent)]
    #[diagnostic(transparent)]
    Lock(#[from] config::LockError),

    /// Structured logging could not be initialized.
    #[error(transparent)]
    #[diagnostic(transparent)]
    Logging(#[from] config::LoggingError),

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
