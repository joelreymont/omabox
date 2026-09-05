#![deny(clippy::expect_used, clippy::panic, clippy::unwrap_used)]

fn main() -> std::process::ExitCode {
    let mut arguments = std::env::args_os().skip(1);
    if arguments.next().as_deref() == Some(std::ffi::OsStr::new("--self-check"))
        && arguments.next().is_none()
    {
        println!("omaboxd {}", env!("CARGO_PKG_VERSION"));
        return std::process::ExitCode::SUCCESS;
    }
    omabox::daemon::entry()
}
