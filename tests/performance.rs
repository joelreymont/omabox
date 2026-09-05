use std::env;
use std::error::Error;
use std::fs;
use std::time::{Duration, Instant};

use omabox::journal::{Journal, LocalRootBinding};
use omabox::local::{ScanPublication, scan_and_publish};
use tempfile::TempDir;

#[test]
#[ignore = "release-only measurement; set OMABOX_PERF_FILES to choose tree size"]
fn warm_idle_scan_and_publication_cost() -> Result<(), Box<dyn Error>> {
    let file_count = match env::var("OMABOX_PERF_FILES") {
        Ok(value) => value.parse::<usize>()?,
        Err(env::VarError::NotPresent) => 10_000,
        Err(source) => return Err(source.into()),
    };
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    fs::create_dir(&root)?;
    for index in 0..file_count {
        fs::write(root.join(format!("{index:05}.txt")), b"stable payload")?;
    }
    std::thread::sleep(Duration::from_secs(4));

    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let _ = journal.activate_local_root(&LocalRootBinding::inspect(&root)?)?;
    assert!(matches!(
        scan_and_publish(&mut journal, &root)?,
        ScanPublication::Published(_)
    ));

    let mut samples = Vec::with_capacity(5);
    for _ in 0..5 {
        let started = Instant::now();
        assert!(matches!(
            scan_and_publish(&mut journal, &root)?,
            ScanPublication::Published(_)
        ));
        samples.push(started.elapsed().as_millis());
    }
    samples.sort_unstable();
    println!(
        "warm idle scan/publication: files={file_count} samples_ms={samples:?} median_ms={}",
        samples[samples.len() / 2]
    );
    Ok(())
}
