#![deny(clippy::expect_used, clippy::panic, clippy::unwrap_used)]

fn main() -> miette::Result<()> {
    omabox::config::initialize_logging()?;
    Ok(())
}
