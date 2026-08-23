#![deny(clippy::expect_used, clippy::panic, clippy::unwrap_used)]

fn main() -> miette::Result<()> {
    omabox::config::initialize_logging()?;
    let config = omabox::config::Config::load()?;
    config.prepare()?;
    let _instance_lock = omabox::config::InstanceLock::acquire(config.paths().lock_file())?;
    tracing::info!(sync_root = %config.sync_root().display(), "daemon instance lock acquired");

    loop {
        std::thread::park();
    }
}
