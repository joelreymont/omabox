#![deny(clippy::expect_used, clippy::panic, clippy::unwrap_used)]

fn main() -> std::process::ExitCode {
    omabox::daemon::entry()
}
