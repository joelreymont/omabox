#![deny(clippy::expect_used, clippy::panic, clippy::unwrap_used)]

pub mod auth;
pub mod config;
pub mod dropbox;
pub mod install;
pub mod journal;
pub mod local;
pub mod model;
pub mod planner;
pub mod reconcile;
pub mod recovery;
pub mod runtime_status;
pub mod service;
mod spawn;
pub mod status;

/// Filesystem helpers shared with the integration tests, which declare the
/// same file as an ordinary module of their own.
#[cfg(test)]
#[path = "../tests/common/mod.rs"]
mod common;
